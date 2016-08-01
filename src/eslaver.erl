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

-define(RDB_FILE, "/tmp/master/dump3.rdb").
-define(SB, <<" ">>). % Binary space bar
-define(CRLF, <<"\r\n">>).

-record(state, {runid="?",
                offset=-1,
                mode,
                state,
                socket,
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
    process_flag(trap_exit, true),
    try initial() of
        {ok, Sock} ->
            gen_server:cast(self(), repl),
            {ok, #state{socket=Sock, state=list}};
        {error, timeout} ->
            io:format("timeout"),
            {stop, timeout};
        {error, Error} ->
            io:format("Error -> '~p' ~n", [Error]),
            {stop, Error}
    catch
        Exception:Reason ->
            {stop, {Exception, Reason}}
    end.

% load_rdb(self()), % load rdb file

%% REPLCONF listening-port.
%% The initial step, send the repl with our
%% client tcp port over the socket.
handle_cast(repl, S = #state{socket=Sock, state=list}) ->
    io:format("repl ~n"),
    handle_sock(repl(Sock), S);

%% REPLCONF capa eof.
%% Check wheter the server is able to do partial
%% synchronization or just can handle whole sync.
handle_cast(capa, S = #state{socket=Sock, state=eof}) ->
    io:format("capa ~n"),
    Type = handle_sock(capa(Sock), S), % BUG: take care of recv errors.
    gen_server:cast(self(), Type),
    {noreply, S#state{state=load, mode=Type}};

%% PSYNC.
handle_cast(psync, S = #state{socket=Sock, state=load}) ->
    io:format("psync ~n"),
    handle_sock(psync(Sock, S#state.runid, S#state.offset), S),
    {noreply, S};

%% SYNC.
handle_cast(sync, S = #state{socket=Sock, state=load}) ->
    io:format("sync ~n"),
    handle_sock(sync(Sock), S);

%% LOAD RDB DATA
handle_cast({load_rdb, Bulk}, S = #state{socket=_Sock, state=lalala}) -> % FIXME
    rdb:save(Bulk, ?RDB_FILE),
    rdb:load(self(), ?RDB_FILE),
    io:format("load_rdb data -> ~p ~n", [Bulk]),
    {noreply, S};

handle_cast(shutdown, State) ->
    io:format("Generic cast: *shutdown* while in '~p'~n",[State]),
    {stop, normal, State};
%% Generic
handle_cast(Msg, State) ->
    io:format("Generic cast: '~p' while in '~p'~n",[Msg, State]),
    {noreply, State}.

%% Generic
handle_call(Msg, From, State) ->
    io:format("Generic call: '~p' from '~p' while in '~p'~n",[Msg, From, State]),
    {reply, ok, State}.

handle_info({loading, list, <<Key/binary>>, [FirstElem|_]}, State) ->
    io:format("key '~s' -> elem '~p' ~n", [Key, FirstElem]),
    {noreply, State};
handle_info({loading, eof}, State) ->
    io:format("rdb synchronization completed ~n"),
    {noreply, State};
%%Generic
handle_info(Msg, State) ->
    io:format("Generic info: '~p' '~p'~n",[Msg, State]),
    {noreply, State}.

%% Code change
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% Server termination
terminate(socket_err, {S, Error}) ->
    io:format("Error over socket ~p ~n", [Error]),
    gen_tcp:close(S#state.socket);
terminate(Reason, State) ->
    io:format("Generic termination: '~p' '~p'~n",[Reason, State]).

%
% Steps to do:
%
% 1- Tcp client connection
% 2- ping
% 3- start slave phase
%    3.1 - [repl]
%    3.2 - [capa] check if servr is psync compat with capa eof
%    3.3 - [sync|psync]


%% Handle the receiving data in socket depending
%% in which state is.
handle_sock(ok, S = #state{socket=Sock, state=list}) ->
    io:format("doing list ~n"),
    case recv_repl(Sock) of
        {ok, _} ->
            gen_server:cast(self(), capa),
            {noreply, S#state{state=eof}}; % Next state will be 'eof'
        {error, Error} ->
            {stop, socket_err, {S, Error}}
    end;
%% Get type of synchronization
handle_sock(ok, S = #state{socket=Sock, state=eof}) ->
    io:format("doing eof ~n"),
    case recv_repl(Sock) of
        {ok, Mode} ->
            Mode;
        {error, Error} -> % BUG in here!!
            {stop, socket_err, {S, Error}}
    end;
%% Receive the payload from de synchronization command 'sync'
handle_sock(ok, S = #state{socket=Sock, state=load, mode=sync}) -> % Remove 'mode=sync' ?
    io:format("getting payload sync ~n"),
    case recv_payload(Sock) of
        {stream, Bulk} ->
            gen_server:cast(self(), {load_rdb, Bulk}),
            {noreply, S#state{state=lalala}}; % Next state will be 'lalala' % FIXME
        {error, Error} ->
            {stop, socket_err, {S, Error}}
    end;

%% Receive the payload from de synchronization command 'psync'
handle_sock(ok, S = #state{socket=Sock, state=load, mode=psync}) -> % Remove 'mode=sync' ?
    io:format("getting payload psync ~n"),
    A = recv_payload(Sock),
    B = recv_payload(Sock),
    io:format("look -> ~p ~n", [A]),
    io:format("look -> ~p ~n", [B]),
    {noreply, S};

handle_sock({error, Error}, S) ->
    {stop, socket_err, {S, Error}};
handle_sock(_,_) ->
    {stop, general, "general socket error"}.


initial() ->
    Addr = {127,0,0,1},
    Port = 6379,
    Sock = connect(Addr, Port),
    case ping(Sock) of
        ok ->
            recv_pong(Sock);
        {error, timeout} ->
            io:format("Send timeout, closing! ~n"),
            gen_tcp:close(Sock),
            throw(timeout);
        {error, OtherSendError} ->
            io:format("Error over initial socket ~n"),
            gen_tcp:close(Sock),
            throw(OtherSendError)
    end.

connect(Addr, Port) when is_tuple(Addr), is_integer(Port) ->
    case tcp_connect(Addr, Port) of
        {ok, Sock} ->
            Sock;
        {error, Error} ->
            throw(Error)
    end;
connect(_, _) ->
    throw("invalid host or port to connect to").

recv_payload(Sock) ->
    inet:setopts(Sock, [{active,once}]),
    receive
        {tcp, Sock, <<"+FULLRESYNC", _, RunId:40/binary, _, Offset/binary>>} ->
            {foo, b2l(RunId), int_offset(Offset)};
        {tcp, _Sock, <<Bulk/binary>>} ->
            {stream, Bulk};
        {tcp, _Sock, Data} ->
            io:format("invalid data received '~p' ~n", [Data]),
            {error, "invalid data received"};
        {tcp_closed, Sock} ->
            io:format("Socket ~w closed [~w]~n", [Sock ,self()]),
            {error, "Tcp socket was closed"};
        _ ->
            {error, "Generic error"}
    end.

recv_repl(Sock) ->
    inet:setopts(Sock, [{active,once}]),
    receive
        {tcp, Sock, <<"+OK", _/binary>>} ->
            {ok, psync};
        {tcp, _Sock, <<"-ERR Unrecognized REPLCONF", _/binary>>} ->
            {ok, sync};
        {tcp, _Sock, Data} ->
            io:format("invalid data received '~p' ~n", [Data]),
            {error, "invalid data received"};
        {tcp_closed, Sock} ->
            io:format("Socket ~w closed [~w]~n", [Sock ,self()]),
            {error, "Tcp socket was closed"};
        _ ->
            {erorr, "Generic error"}
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

tcp_connect(Addr, Port) ->
    gen_tcp:connect(Addr, Port, [binary, {active, false}]).

load_rdb(Pid) when is_pid(Pid) ->
    rdb:load(Pid, ?RDB_FILE);
load_rdb(_) ->
    {error, "invalid pid to load rdb"}.

save_rdb(Data) when is_binary(Data) ->
    rdb:save(Data, ?RDB_FILE);
save_rdb(_) ->
    {error, "invalid rdb data"}.

send_pkg(Sock, Pkt) when is_list(Pkt) ->
    io:format("pkt -> ~p ~n", [Pkt]),
    gen_tcp:send(Sock, [Pkt] ++ ?CRLF);
send_pkg(_, _) ->
    throw("cannot send invalid tcp paquet").

ping(Sock) ->
    send_pkg(Sock, [<<"PING">>]).

auth(Sock, MasterAuth) ->
    send_pkg(Sock, [<<"AUTH">>, ?SB, list_to_binary(MasterAuth)]).

capa(Sock) ->
    send_pkg(Sock, [<<"REPLCONF capa eof">>]).

repl(Sock) ->
    send_pkg(Sock, [<<"REPLCONF listening-port">>, ?SB, get_lport(Sock)]).

sync(Sock) ->
    send_pkg(Sock, [<<"SYNC">>]).

psync(Sock, RunId, Offset) ->
    send_pkg(Sock, [<<"PSYNC">>, ?SB, l2b(RunId), ?SB, i2b(Offset)]).

%% Get client listen port in binary format
get_lport(Sock) ->
    {ok, Port} = inet:port(Sock),
    i2b(Port).

%% Short func for 'binary_to_list'
b2l(B) when is_binary(B) ->
    binary_to_list(B).

%% Short func for 'list_to_binary'
l2b(L) when is_list(L) ->
    list_to_binary(L).

%% Short func for 'integer_to_binary'
i2b(I) when is_integer(I) ->
    list_to_binary(integer_to_list(I)).

%% Convert -> <<"666\r\n">> to normal integer
int_offset(B) when is_binary(B) ->
    B2 = hd(binary:split(B, <<"\r\n">>)), % First element of binary
    binary_to_integer(B2);
int_offset(_) ->
    throw("error in binary offset").