-module(redis).

-export([rsize/1, rlen/1]).


%%
%% Redis proto funcs
%%

%% Short func to redis proto size element.
%% -> <<"$1">>.
rsize(N) when is_integer(N) ->
    redis_int_to_bin(36, N);
rsize(_) ->
    error.

%% Short func to redis proto length element.
%% -> <<"*1">>
rlen(N) when is_integer(N) ->
    redis_int_to_bin(42, N);
rlen(_) ->
    error.

redis_int_to_bin(Char, N) ->
    S = [Char, eslaver_utils:i2l(N)],
    eslaver_utils:l2b(S).
