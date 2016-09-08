-module(eslaver_sup).
-behaviour(supervisor).
-export([start_link/0, init/1]).


start_link() ->
    supervisor:start_link({global,?MODULE}, ?MODULE, normal).

init(normal) ->
    {ok, {{one_for_one, 3, 10},
          [{eslaver,
            {eslaver_server, start, []},
            permanent,
            5000,
            worker,
            [eslaver_server]
          }]}}.
