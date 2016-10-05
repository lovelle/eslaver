-module(eslaver_sup).
-behaviour(supervisor).
-export([start_link/1, init/1]).


start_link(Args) ->
    supervisor:start_link({global,?MODULE}, ?MODULE, {normal, Args}).

init({normal, Args}) ->
    {ok, {{one_for_one, 3, 10},
          [{eslaver,
            {eslaver_server, start, [Args]},
            permanent,
            5000,
            worker,
            [eslaver_server]
          }]}}.
