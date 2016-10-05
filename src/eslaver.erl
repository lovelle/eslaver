-module(eslaver).
-behaviour(application).
-export([start/2, stop/1]).


start(normal, Args) ->
    eslaver_sup:start_link(Args).

stop(_State) ->
    %eslaver_sup:stop().
    ok.
