-module(test_wx_win).

-include_lib("wx/include/wx.hrl").
-include_lib("wx/include/gl.hrl").
-behaviour(wx_object).

-export([start/0, start/1, start_link/0, start_link/1,
        init/1, terminate/2, code_change/3,
        handle_info/2, handle_call/3, handle_event/2]).

-define(FRAME_MS, 1).         %% to observe max practical speed of timeout-based render loop
-define(FPS_WINDOW_MS, 500).  %% how often the displayed fps is recomputed

%% On-screen FPS overlay (HUD). Drawn as an opaque box straight into the RGBA
%% backing buffer, using a tiny 3x5 bitmap font (see glyph/1).
-define(HUD_X, 4).        %% top-left margin in backing-buffer pixels
-define(HUD_Y, 4).
-define(HUD_SCALE, 3).    %% each font pixel becomes a SCALE x SCALE block
-define(GLYPH_W, 3).
-define(GLYPH_H, 5).
-define(HUD_FG, <<0, 255, 0, 255>>).   %% glyph colour (opaque green)
-define(HUD_BG, <<0, 0, 0, 255>>).     %% box background (opaque black)

-record(state, {sb, frame, canvas, context,
                tex,        %% GL texture id we blit the backing buffer into
                buf,        %% the backing buffer (RGBA bytes), using mut_bin library
                tw, th,     %% backing buffer width/height in pixels
                mode,       %% windowing mode: windowed | windowed_fullscreen | fullscreen
                last_t,     %% monotonic ms at the start of the current fps window
                frames=0,   %% frames drawn since last_t
                fps=0}).    %% last computed fps, shown in the HUD

%% Windowing mode :: windowed | windowed_fullscreen | fullscreen
start() ->
    start(windowed).

start(Mode) ->
    wx_object:start(?MODULE, Mode, []).

start_link() ->
    start_link(windowed).

start_link(Mode) ->
    Res = wx_object:start_link(?MODULE, Mode, []),
    {ok,wx_object:get_pid(Res)}.

init(Mode) ->
    wx:new(),
    process_flag(trap_exit, true),
    %% Always create the frame DECORATED, regardless of the target mode. On
    %% Wayland an undecorated (?wxNO_BORDER) top-level cannot be maximized: the
    %% set_maximized request on a borderless surface that owns a GL canvas is a
    %% fatal protocol error. A decorated frame maximizes fine, and fullscreen
    %% still hides the decorations on top. Trade-off: windowed_fullscreen keeps
    %% its title bar (on Wayland, borderless-fill == fullscreen anyway).
    %%
    %% The screen-filling state (maximize/fullscreen) is then applied after the
    %% first render -- see the {apply_mode, _} handler -- because doing it during
    %% init races the compositor's first surface configure.
    Frame = wxFrame:new(wx:null(), ?wxID_ANY, "test_wx_win",
                        [{size,{640,480}}, {style, frame_style(windowed)}]),
    Attrs = [?WX_GL_RGBA, ?WX_GL_DOUBLEBUFFER, ?WX_GL_DEPTH_SIZE, 24, 0],
    Canvas = wxGLCanvas:new(Frame, [{attribList, Attrs}]),

    %% Mouse events (delivered to handle_event/2 as #wx{event=#wxMouse{}}).
    wxGLCanvas:connect(Canvas, left_down),
    wxGLCanvas:connect(Canvas, left_up),
    wxGLCanvas:connect(Canvas, right_down),
    wxGLCanvas:connect(Canvas, right_up),
    wxGLCanvas:connect(Canvas, motion),
    wxGLCanvas:connect(Canvas, mousewheel),

    %% Keyboard events (#wx{event=#wxKey{}}). The canvas must hold focus
    %% to receive these, so grab it once the window is shown.
    wxGLCanvas:connect(Canvas, key_down),
    wxGLCanvas:connect(Canvas, key_up),
    wxGLCanvas:connect(Canvas, char),

    %% Let the window close cleanly via the title-bar [x].
    wxFrame:connect(Frame, close_window),

    %% Keep the GL viewport in sync with the (resizable) window. The frame
    %% auto-resizes its single child canvas to fill the client area, so the
    %% canvas's own size event carries the new dimensions. {skip,true} lets
    %% wx run its default size handling too.
    wxGLCanvas:connect(Canvas, size, [{skip, true}]),

    %% A GL context is the thing that actually owns the rendering state.
    %% Create it once; make it "current" each frame before drawing.
    Context = wxGLContext:new(Canvas),

    wxFrame:show(Frame),
    wxWindow:setFocus(Canvas),

    %% The context can only be made current once the window is shown, and
    %% the texture has to be created while a context is current.
    wxGLCanvas:setCurrent(Canvas, Context),
    gl:clearColor(0.0, 0.0, 0.0, 1.0),

    %% Build a mutable backing buffer and allocate a texture from it.
    W = 256, H = 256,
    Buf = make_buffer(W, H),
    %% Get pointer to pixels from mutable binary
    {Pixels, _} = mut_bin:data(Buf),
    Tex = init_texture(W, H, Pixels),

    %% Kick off the render loop, then apply the windowing mode. Both are
    %% queued as messages and render is enqueued first, so by the time
    %% {apply_mode, _} is handled the surface has been committed and
    %% configured -- the same conditions the runtime 1/2/3 keys rely on.
    self() ! render,
    self() ! {apply_mode, Mode},
    {Frame,#state{frame=Frame, canvas=Canvas, context=Context,
                  tex=Tex, buf=Buf, tw=W, th=H, mode=Mode,
                  last_t=erlang:monotonic_time(millisecond)}}.

%% Frame style flags per windowing mode. NOTE: init currently always creates
%% with frame_style(windowed), because on Wayland a ?wxNO_BORDER top-level
%% can't be maximized without a fatal protocol error. The borderless clauses
%% are kept for platforms where creating directly in the target style works
%% (X11, Windows, macOS).
frame_style(windowed)            -> ?wxDEFAULT_FRAME_STYLE;
frame_style(windowed_fullscreen) -> ?wxNO_BORDER;
frame_style(fullscreen)          -> ?wxNO_BORDER.

%% Switch the (already-shown) frame into a windowing mode, from whatever mode
%% it is currently in -- used both at init and for the 1/2/3 runtime toggles.
%%  - fullscreen:          true compositor fullscreen, all decorations hidden.
%%  - windowed_fullscreen: borderless window maximized to fill the screen.
%%  - windowed:            normal decorated window the WM/compositor can move.
%%
%% Only Wayland-safe operations here: showFullScreen on/off and maximize/
%% restore. We never change the border at runtime (setWindowStyleFlag on a live
%% GL surface is a fatal Wayland protocol error), and the frame is always
%% created decorated (see init). So the title bar is present in both windowed
%% and windowed_fullscreen, and only hidden by true fullscreen.
set_mode(Frame, fullscreen) ->
    wxTopLevelWindow:showFullScreen(Frame, true, [{style, ?wxFULLSCREEN_ALL}]);
set_mode(Frame, windowed_fullscreen) ->
    unfullscreen(Frame),
    wxTopLevelWindow:maximize(Frame);
set_mode(Frame, windowed) ->
    unfullscreen(Frame),
    wxTopLevelWindow:maximize(Frame, [{maximize, false}]).

%% showFullScreen(false) only makes sense when actually fullscreen.
unfullscreen(Frame) ->
    case wxTopLevelWindow:isFullScreen(Frame) of
        true  -> wxTopLevelWindow:showFullScreen(Frame, false);
        false -> ok
    end.

%% Create a texture sized for the backing buffer and upload the initial
%% contents. NEAREST filtering gives a crisp 1:1 blit (no smoothing).
init_texture(W, H, Pixels) ->
    [Tex] = gl:genTextures(1),
    gl:bindTexture(?GL_TEXTURE_2D, Tex),
    gl:texParameteri(?GL_TEXTURE_2D, ?GL_TEXTURE_MIN_FILTER, ?GL_NEAREST),
    gl:texParameteri(?GL_TEXTURE_2D, ?GL_TEXTURE_MAG_FILTER, ?GL_NEAREST),
    gl:texImage2D(?GL_TEXTURE_2D, 0, ?GL_RGBA, W, H, 0,
                  ?GL_RGBA, ?GL_UNSIGNED_BYTE, Pixels),
    Tex.

%% A throwaway gradient so there's something on screen. Row-major,
%% top row first, 4 bytes (R,G,B,A) per pixel.
make_buffer(W, H) ->
    Size = 4 * W * H,
    {ok, MBin} = mut_bin:alloc(Size),

    %% Temporary immutable binary is used to initialize the mutable
    Bin = << << (X rem 256), (Y rem 256), 128, 255 >>
             || Y <- lists:seq(0, H - 1), X <- lists:seq(0, W - 1) >>,
    ok = mut_bin:copy(MBin, 0, Bin, 0, Size),
    MBin.

%% The render function. Everything between setCurrent and swapBuffers is
%% drawn into the back buffer; swapBuffers flips it onto the screen.
render(#state{canvas=Canvas, context=Context, tex=Tex,
              buf=MBuf, tw=W, th=H, fps=Fps}) ->
    wxGLCanvas:setCurrent(Canvas, Context),

    %% Upload the current backing buffer into the texture. texSubImage2D
    %% reuses the existing allocation (cheaper than texImage2D each frame).
    gl:bindTexture(?GL_TEXTURE_2D, Tex),

    %% Stamp the FPS overlay straight into the backing buffer so it rides
    %% along with this frame's upload. This mutates the same memory Pixels
    %% points at, so it must happen before texSubImage2D reads it.
    draw_hud(MBuf, W, H, Fps),

    %% Get pointer to pixels from mutable binary
    {Pixels, _} = mut_bin:data(MBuf),
    gl:texSubImage2D(?GL_TEXTURE_2D, 0, 0, 0, W, H,
                     ?GL_RGBA, ?GL_UNSIGNED_BYTE, Pixels),

    %% Draw the texture on a quad that fills clip space [-1,1]^2. With the
    %% default identity projection/modelview that's exactly the viewport,
    %% so no matrix setup is needed.
    gl:clear(?GL_COLOR_BUFFER_BIT),
    gl:enable(?GL_TEXTURE_2D),
    gl:'begin'(?GL_QUADS),
    gl:texCoord2f(0.0, 0.0), gl:vertex2f(-1.0,  1.0),  %% top-left
    gl:texCoord2f(1.0, 0.0), gl:vertex2f( 1.0,  1.0),  %% top-right
    gl:texCoord2f(1.0, 1.0), gl:vertex2f( 1.0, -1.0),  %% bottom-right
    gl:texCoord2f(0.0, 1.0), gl:vertex2f(-1.0, -1.0),  %% bottom-left
    gl:'end'(),
    gl:disable(?GL_TEXTURE_2D),

    wxGLCanvas:swapBuffers(Canvas).

%% Frame-rate measurement. Counts frames within a ~?FPS_WINDOW_MS window of
%% monotonic time (so the reading is unaffected by wall-clock adjustments) and
%% recomputes the displayed fps once per window.
tick_fps(State=#state{last_t=Last, frames=Frames0}) ->
    Frames = Frames0 + 1,
    Now = erlang:monotonic_time(millisecond),
    Dt = Now - Last,
    case Dt >= ?FPS_WINDOW_MS of
        true  -> State#state{fps=round(Frames * 1000 / Dt), frames=0, last_t=Now};
        false -> State#state{frames=Frames}
    end.

%% --- On-screen FPS overlay -------------------------------------------------
%% Rasterise "<n> fps" straight into the RGBA backing buffer as an opaque box
%% (so it overwrites whatever was there last frame -- no need to restore the
%% pixels underneath). Only mut_bin:copy/5 mutates the buffer, so the mut_bin
%% NIF itself stays untouched.

fps_text(Fps) ->
    integer_to_list(Fps) ++ " fps".

draw_hud(MBuf, W, H, Fps) ->
    Text = fps_text(Fps),
    %% Each char is GLYPH_W px wide plus a 1px inter-glyph gap, scaled up.
    BoxW = length(Text) * (?GLYPH_W + 1) * ?HUD_SCALE,
    BoxH = ?GLYPH_H * ?HUD_SCALE,
    case (?HUD_X + BoxW =< W) andalso (?HUD_Y + BoxH =< H) of
        false ->
            %% Window too small for the overlay; skip to stay in bounds.
            ok;
        true ->
            lists:foreach(
              fun(Sy) ->
                      RowBin = hud_row(Text, Sy div ?HUD_SCALE),
                      Offset = ((?HUD_Y + Sy) * W + ?HUD_X) * 4,
                      ok = mut_bin:copy(MBuf, Offset, RowBin, 0, byte_size(RowBin))
              end,
              lists:seq(0, BoxH - 1))
    end.

%% One screen row (BoxW pixels of RGBA) for font row Fr across all chars.
hud_row(Text, Fr) ->
    list_to_binary([ glyph_row(C, Fr) || C <- Text ]).

%% Pixels for a single char on font row Fr: GLYPH_W cells (msb = leftmost) plus
%% one trailing gap cell, each scaled horizontally by HUD_SCALE.
glyph_row(C, Fr) ->
    Bits = lists:nth(Fr + 1, glyph(C)),
    Cells = [ bit_pixel(Bits, Col) || Col <- lists:seq(?GLYPH_W - 1, 0, -1) ],
    list_to_binary(Cells ++ [dup(?HUD_BG, ?HUD_SCALE)]).

bit_pixel(Bits, Col) ->
    case (Bits bsr Col) band 1 of
        1 -> dup(?HUD_FG, ?HUD_SCALE);
        0 -> dup(?HUD_BG, ?HUD_SCALE)
    end.

%% Repeat a 4-byte pixel binary N times.
dup(Pixel, N) ->
    list_to_binary(lists:duplicate(N, Pixel)).

%% 3x5 bitmap font: each glyph is 5 rows of 3 bits (msb = leftmost pixel).
%% Only the characters needed for "<n> fps" are defined; anything else (incl.
%% space) renders blank.
glyph($0) -> [2#111,2#101,2#101,2#101,2#111];
glyph($1) -> [2#010,2#110,2#010,2#010,2#111];
glyph($2) -> [2#111,2#001,2#111,2#100,2#111];
glyph($3) -> [2#111,2#001,2#111,2#001,2#111];
glyph($4) -> [2#101,2#101,2#111,2#001,2#001];
glyph($5) -> [2#111,2#100,2#111,2#001,2#111];
glyph($6) -> [2#111,2#100,2#111,2#101,2#111];
glyph($7) -> [2#111,2#001,2#010,2#100,2#100];
glyph($8) -> [2#111,2#101,2#111,2#101,2#111];
glyph($9) -> [2#111,2#101,2#111,2#001,2#111];
glyph($f) -> [2#011,2#100,2#110,2#100,2#100];
glyph($p) -> [2#110,2#101,2#110,2#100,2#100];
glyph($s) -> [2#011,2#100,2#010,2#001,2#110];
glyph(_)  -> [2#000,2#000,2#000,2#000,2#000].

handle_info(render, State0) ->
    %% Schedule the next frame first so the period is ~FRAME_MS regardless
    %% of how long this frame's render takes.
    erlang:send_after(?FRAME_MS, self(), render),
    State = tick_fps(State0),
    render(State),
    {noreply,State};
handle_info({apply_mode, Mode}, State=#state{frame=Frame}) ->
    %% Deferred from init: now that the first frame is rendered and the
    %% surface is configured, switch into the startup mode via the same path
    %% the runtime keys use.
    set_mode(Frame, Mode),
    {noreply,State};
handle_info(Msg, State) ->
    io:format("handle_info cb: ~p~n", [Msg]),
    {noreply,State}.

handle_call(Msg, _From, State) ->
    io:format("handle_call cb: ~p~n", [Msg]),
    {reply,ok,State}.

handle_event(#wx{event=#wxSize{size={W,H}}},
             State=#state{canvas=Canvas,context=Context,tex=Tex})
  when W > 0, H > 0 ->
    %% gl:* are GL calls, so make the context current first.
    wxGLCanvas:setCurrent(Canvas, Context),
    gl:viewport(0, 0, W, H),

    %% Resize the backing buffer to the new window size and REALLOCATE the
    %% texture storage to match (texImage2D, not texSubImage2D, since the
    %% dimensions changed). render/1 then resumes its cheap texSubImage2D
    %% uploads at the new size.
    Buf = make_buffer(W, H),
    gl:bindTexture(?GL_TEXTURE_2D, Tex),

    %% Get pointer to pixels from mutable binary
    {Pixels, _} = mut_bin:data(Buf),
    gl:texImage2D(?GL_TEXTURE_2D, 0, ?GL_RGBA, W, H, 0,
                  ?GL_RGBA, ?GL_UNSIGNED_BYTE, Pixels),

    %% Deallocate the previous mutable binary
    case State#state.buf of
        undefined ->
            ok;
        MB ->
            mut_bin:dealloc(MB)
    end,

    {noreply,State#state{buf=Buf,tw=W,th=H}};
handle_event(#wx{event=#wxSize{}}, State) ->
    %% Degenerate size (e.g. minimized to 0xN); nothing to do.
    {noreply,State};
handle_event(#wx{event=#wxMouse{type=Type,x=X,y=Y}}, State) ->
    io:format("mouse ~p at (~p,~p)~n", [Type, X, Y]),
    {noreply,State};
handle_event(#wx{event=#wxKey{type=key_down,keyCode=?WXK_ESCAPE}}, #state{frame=Frame}=State) ->
    io:format("ESC key down~n", []),
    wxFrame:destroy(Frame),
    {stop,normal,State};
%% 1/2/3 switch windowing mode at runtime (main number row, not numpad).
handle_event(#wx{event=#wxKey{type=key_down,keyCode=$1}}, State=#state{frame=Frame}) ->
    set_mode(Frame, fullscreen),
    {noreply,State#state{mode=fullscreen}};
handle_event(#wx{event=#wxKey{type=key_down,keyCode=$2}}, State=#state{frame=Frame}) ->
    set_mode(Frame, windowed_fullscreen),
    {noreply,State#state{mode=windowed_fullscreen}};
handle_event(#wx{event=#wxKey{type=key_down,keyCode=$3}}, State=#state{frame=Frame}) ->
    set_mode(Frame, windowed),
    {noreply,State#state{mode=windowed}};
handle_event(#wx{event=#wxKey{type=Type,keyCode=Key}}, State) ->
    io:format("key ~p code=~p~n", [Type, Key]),
    {noreply,State};
handle_event(#wx{event=#wxClose{}},State=#state{frame=Frame}) ->
    wxFrame:destroy(Frame),
    {stop,normal,State};
handle_event(Event, State) ->
    io:format("handle_event cb: ~p~n", [Event]),
    {noreply,State}.

code_change(_, _, State) ->
    {ok,State}.

terminate(_Reason, _State) ->
    wx:destroy().
