-module(eslaver).
-behaviour(application).
-export([start/2, stop/1]).


start(normal, []) ->
    eslaver_server:start().

stop(_State) ->
    ok.
