-module(eslaver).
-behaviour(application).
-export([start/2, stop/1]).


start(normal, _Args) ->
    eslaver_sup:start_link().

stop(_State) ->
    %eslaver_sup:stop().
    ok.
