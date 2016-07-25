-module(eslaver_supervisor).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, normal).

init(normal) ->
    init({one_for_one, 3, 60}).
