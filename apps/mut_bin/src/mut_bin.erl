-module(mut_bin).

-export([alloc/1, dealloc/1, data/1, copy/5, to_erl/1]).
-nifs([alloc/1, dealloc/1, data/1, copy/5, to_erl/1]).
-on_load(init/0).

init() ->
    Name = filename:join(code:priv_dir(?MODULE), ?MODULE),
    erlang:load_nif(Name, 0).


-doc "Allocate an unmanaged binary. Caller must manually free the memory by calling `dealloc/1`.".
-spec alloc(integer()) -> {ok, term()} | {error, term()}.
alloc(_Size) ->
    erlang:nif_error(nif_library_not_loaded).


-doc "Deallocate an unmanaged binary created with `alloc/1`. ".
-spec dealloc(term()) -> ok.
dealloc(_Ptr) ->
    erlang:nif_error(nif_library_not_loaded).


-doc "Return offset (from 0x00) and size in bytes of binary resource.".
-spec data(term()) -> {Offset::integer(), Size::integer()}.
data(_Ptr) ->
    erlang:nif_error(nif_library_not_loaded).


-doc "Copy data into binary resource. Source may be an Erlang binary or a mut_bin resource.".
-spec copy(term(), integer(), term(), integer(), integer()) -> ok | {error, term()}.
copy(_Dst, _DstOffset, _Src, _SrcOffset, _Count) ->
    erlang:nif_error(nif_library_not_loaded).

-spec to_erl(term()) -> binary().
to_erl(_Ptr) ->
    erlang:nif_error(nif_library_not_loaded).
