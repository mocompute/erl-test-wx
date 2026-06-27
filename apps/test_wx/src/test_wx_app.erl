%%%-------------------------------------------------------------------
%% @doc test_wx public API
%% @end
%%%-------------------------------------------------------------------

-module(test_wx_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    test_wx_sup:start_link().

stop(_State) ->
    ok.

%% internal functions
