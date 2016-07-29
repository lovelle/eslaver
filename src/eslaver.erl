-module(eslaver).
-behaviour(gen_server).

% API calls
-export([start/0, stop/0]).

% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-define(RDB_FILE, "/tmp/master/dump2.rdb").

-record(state, {runid="?",
                offset=-1,
                socket,
                state,
                monitor,
                from}).


%%====================================================================
%% API calls
%%====================================================================
start() ->
    gen_server:start_link(?MODULE, [], []).

stop() ->
    gen_server:call(?MODULE, shutdown).

%%====================================================================
%% gen_server callbacks
%%====================================================================
init([]) ->
    {ok, Socket} = initial(),

    gen_server:cast(self(), accept),
    {ok, #state{socket=Socket, state=init}}.

%% Start rdb slavery
handle_cast(accept, S = #state{socket=Socket}) ->
    load_rdb(self()),
    io:format("mira -> ~p ~n", [Socket]),
    {noreply, S};
handle_cast(shutdown, State) ->
    io:format("Generic cast: *shutdown* while in '~p'~n",[State]),
    {stop, normal, State};
%% generic
handle_cast(Msg, State) ->
    io:format("Generic cast: '~p' while in '~p'~n",[Msg, State]),
    {noreply, State}.


handle_call(Msg, From, State) ->
    io:format("Generic call: '~p' from '~p' while in '~p'~n",[Msg, From, State]),
    {reply, ok, State}.


handle_info(Msg, State) ->
    io:format("Generic info: '~p' '~p'~n",[Msg, State]),
    {noreply, State}.

%% Code change
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% Server termination
terminate(Reason, State) ->
    io:format("Generic termination: '~p' '~p'~n",[Reason, State]).

%
% Steps to do:
%
% 1- Tcp client connection
% 2- ping
% 3- start slave phase

initial() ->
    Sock = connect(),
    case ping(Sock) of
        ok ->
            recv_pong(Sock);
        {error, timeout} ->
            io:format("Send timeout, closing! ~n"),
            gen_tcp:close(Sock),
            exit(timeout);
        {error, OtherSendError} ->
            io:format("Error over initial socket ~n"),
            gen_tcp:close(Sock),
            exit(OtherSendError)
    end.

connect() ->
    case tcp_connect() of
        {ok, Sock} ->
            Sock;
        {error, Error} ->
            exit(Error)
    end.

recv_pong(Sock) ->
    inet:setopts(Sock, [{active,once}]),
    receive
        {tcp, Sock, <<"+PONG", _/binary>>} ->
            {ok, Sock};
        {tcp, Sock, Data} ->
            io:format("invalid data received '~p' ~n", [Data]),
            {error, "invalid data received for pong"};
        {tcp_closed, Sock} ->
            io:format("Socket ~w closed [~w]~n",[Sock ,self()]),
            {error, "Tcp socket was closed"}
    end.

tcp_connect() ->
    gen_tcp:connect({127,0,0,1}, 6379, [binary, {active, false}]).

load_rdb(Pid) when is_pid(Pid) ->
    rdb:load(Pid, ?RDB_FILE);
load_rdb(_) ->
    exit("invalid pid to load rdb").

save_rdb(Data) when is_binary(Data) ->
    rdb:save(Data, ?RDB_FILE);
save_rdb(_) ->
    exit("invalid rdb data").

send_pkt(Sock, Pkt) when is_binary(Pkt) ->
    gen_tcp:send(Sock, Pkt);
send_pkt(_, _) ->
    exit("cannot send invalid tcp paquet").

ping(Sock) ->
    send_pkt(Sock, <<"PING\r\n">>).
