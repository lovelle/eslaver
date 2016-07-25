-module(eslaver).
-behaviour(gen_server).

-export([start_link/0, stop/0]).

%% gen_server
-export([init/1, code_change/3, terminate/2]).

-record(state, {runid="?", offset=-1}).


start_link() ->
    gen_server:start_link({local}, ?MODULE, [], []).


stop() ->
    gen_server:call(stop).

init(_Args) ->
    ok.



code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


terminate(normal, S) ->
    io:format("~s normaly shutdown (~s) ~n", [S#state.runid, S#state.offset]);
terminate(conn_refuse, S) ->
    io:format("~s connection refused (~s) ~n", [S#state.runid, S#state.offset]);
terminate(shutdown, S) ->
    io:format("Client request server terminate, ~s ~n", [S#state.runid]);
terminate(_Reason, S) ->
    io:format("~s unexpected terminate! (~s), ~n", [S#state.runid, S#state.offset]).
