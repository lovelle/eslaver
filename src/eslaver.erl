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
-define(BS, <<" ">>). % Binary blank space
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
    gen_server:start_link({global, ?MODULE}, ?MODULE, [], []).

stop() ->
    gen_server:call({global, ?MODULE}, shutdown).

%%====================================================================
%% gen_server callbacks
%%====================================================================
init([]) ->
    process_flag(trap_exit, true),
    try initial() of
        {ok, pong, Sock} ->
            gen_server:cast(self(), repl),
            {ok, #state{socket=Sock, state=list}};
        {error, timeout} ->
            % io:format("timeout"),
            {stop, timeout};
        {error, Reason} ->
            % io:format("Error -> '~p' ~n", [Reason]),
            {stop, Reason}
    catch
        Exception:Reason ->
            {stop, {Exception, Reason}}
    end.

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
    handle_sock(capa(Sock), S);

%% PSYNC.
handle_cast(psync, S = #state{socket=Sock, state=load}) ->
    io:format("psync ~n"),
    handle_sock(psync(Sock, S#state.runid, S#state.offset), S);

%% SYNC.
handle_cast(sync, S = #state{socket=Sock, state=load}) ->
    io:format("sync ~n"),
    handle_sock(sync(Sock), S);

%% First step of receiving payload when is psync.
handle_cast(psync, S = #state{state=payload}) ->
    io:format("psync payload -> ~n"),
    handle_sock(get_payload, S);

%% RDB SAVE
handle_cast({save_rdb, Bulk}, S = #state{state=payload}) ->
    io:format("save_rdb data -> ~p ~n", [Bulk]),
    ok = rdb_save(Bulk),
    gen_server:cast(self(), {load_rdb, self()}),
    {noreply, S};

%% RDB LOAD
handle_cast({load_rdb, Pid}, S = #state{state=payload}) ->
    io:format("load_rdb data -> ~p ~n", [Pid]),
    ok = rdb_load(Pid), % Fixme, rdb_load parse can be '{error, Reason}'
    gen_server:cast(self(), replication), % Move this to eof handle_info
    {noreply, S#state{state=stream}};

%% Stream replication
handle_cast(replication, S = #state{socket=Sock, state=stream}) ->
    io:format("receive stream ~n"),
    inet:setopts(Sock, [{active,once}]),
    {noreply, S};

%% Generic
handle_cast(Msg, State) ->
    io:format("Generic cast: '~p' while in '~p'~n",[Msg, State]),
    {noreply, State}.

handle_call(shutdown, _From, State) ->
    io:format("Generic call: *shutdown* while in '~p'~n",[State]),
    {stop, normal, ok, State};
%% Generic
handle_call(Msg, _From, State) ->
    io:format("Generic cast: '~p' while in '~p'~n",[Msg, State]),
    {noreply, State}.

%handle_info({loading, list, <<Key/binary>>, [FirstElem|_]}, State) ->
%    io:format("key '~s' -> elem '~p' ~n", [Key, FirstElem]),
%    {noreply, State};
handle_info({loading, eof}, State) ->
    io:format("rdb synchronization completed ~n"),
    {noreply, State};

handle_info({tcp, Sock, Data}, State) ->
    io:format("tcp stream: '~p' '~p'~n",[Data, State]),
    inet:setopts(Sock, [{active,once}]),
    {noreply, State};
%% Generic
handle_info(Msg, State) ->
    io:format("Generic info: '~p' '~p'~n",[Msg, State]),
    {noreply, State}.

%% Code change
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% Server termination
terminate(socket_err, {S, Reason}) ->
    gen_tcp:close(S#state.socket),
    io:format("Error over socket ~p ~n", [Reason]);
terminate(Reason, State) ->
    gen_tcp:close(State#state.socket),
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
    case recv_sock(Sock) of
        {ok, _} ->
            gen_server:cast(self(), capa),
            {noreply, S#state{state=eof}}; % Next state will be 'eof'
        {error, Reason} ->
            {stop, socket_err, {S, Reason}}
    end;
%% Get type of synchronization
handle_sock(ok, S = #state{socket=Sock, state=eof}) ->
    io:format("doing eof ~n"),
    case recv_sock(Sock) of
        {ok, Type} ->
            gen_server:cast(self(), Type),
            {noreply, S#state{state=load, mode=Type}};
        {error, Reason} -> % BUG in here!!
            {stop, socket_err, {S, Reason}}
    end;
%% Receive the payload from de synchronization command 'sync'
handle_sock(ok, S = #state{socket=Sock, state=load, mode=sync}) ->
    io:format("getting payload sync ~n"),
    handle_recv(recv_sock(Sock), S);

handle_sock(ok, S = #state{socket=Sock, state=load, mode=psync}) ->
    io:format("getting payload psync 1st ~n"),
    handle_recv(recv_sock(Sock), S);

handle_sock(get_payload, S = #state{socket=Sock, state=payload, mode=psync}) ->
    io:format("getting payload psync 2nd ~n"),
    handle_recv(recv_sock(Sock), S);

handle_sock({error, Reason}, S) ->
    {stop, socket_err, {S, Reason}};
handle_sock(_,_) ->
    {stop, general, "general socket error"}.


handle_recv({ok, fullresync, RunId, Offset}, S) ->
    gen_server:cast(self(), psync),
    {noreply, S#state{state=payload, runid=RunId, offset=Offset}}; % Next state will be 'payload'
handle_recv({ok, load_stream, Bulk}, S) ->
    gen_server:cast(self(), {save_rdb, Bulk}),
    {noreply, S#state{state=payload}}; % Next state will be 'payload'
handle_recv({error, Reason}, S) ->
    {stop, socket_err, {S, Reason}}.


initial() ->
    Addr = {127,0,0,1},
    Port = 6379,
    Pass = undef,
    Sock = connect(Addr, Port),

    case do_auth(Pass) of
        true -> send_auth(Sock, Pass);
        false -> false
    end,
    send_ping(Sock).

send_ping(Sock) ->
    case ping(Sock) of
        ok ->
            recv_sock(Sock);
        {error, timeout} ->
            gen_tcp:close(Sock),
            throw(timeout);
        {error, OtherSendError} ->
            gen_tcp:close(Sock),
            throw(OtherSendError)
    end.

send_auth(Sock, Pass) ->
    case auth(Sock, Pass) of
        ok ->
            case recv_sock(Sock) of
                {ok, _} ->
                    ok;
                {error, Error} ->
                    gen_tcp:close(Sock),
                    throw(Error)
            end;
        {error, OtherSendError} ->
            gen_tcp:close(Sock),
            throw(OtherSendError)
    end.

recv_sock(Sock) ->
    inet:setopts(Sock, [{active,once}]),
    receive
        % "-LOADING"
        {tcp, Sock, <<"+OK", _/binary>>} ->
            {ok, psync};
        {tcp, Sock, <<"+PONG", _/binary>>} ->
            {ok, pong, Sock};
        {tcp, Sock, <<"+FULLRESYNC", _, RunId:40/binary, _, Offset/binary>>} ->
            {ok, fullresync, b2l(RunId), int_offset(Offset)};
        {tcp, _Sock, <<"-ERR Unrecognized REPLCONF", _/binary>>} ->
            {ok, sync};
        {tcp, _Sock, <<"-", Error/binary>>} ->
            {error, Error};
        {tcp, _Sock, <<Bulk/binary>>} ->
            {ok, load_stream, Bulk};
        {tcp, _Sock, Data} ->
            io:format("invalid data received '~p' ~n", [Data]),
            {error, "invalid data received"};
        {tcp_closed, Sock} ->
            io:format("Socket ~w closed [~w]~n", [Sock ,self()]),
            {error, "Tcp socket was closed"};
        _ ->
            {error, "Generic error"}
    end.

connect(Addr, Port) when is_tuple(Addr), is_integer(Port) ->
    case tcp_connect(Addr, Port) of
        {ok, Sock} ->
            Sock;
        {error, Reason} ->
            throw(Reason)
    end;
connect(_, _) ->
    throw("invalid host or port to connect to").

tcp_connect(Addr, Port) ->
    gen_tcp:connect(Addr, Port, [binary, {active, false}]).

rdb_load(Pid) when is_pid(Pid) ->
    rdb:load(Pid, ?RDB_FILE);
rdb_load(_) ->
    {error, "invalid pid to load rdb"}.

rdb_save(Data) when is_binary(Data) ->
    rdb:save(Data, ?RDB_FILE);
rdb_save(_) ->
    {error, "invalid rdb data"}.

send_pkg(Sock, Pkt) when is_list(Pkt) ->
    gen_tcp:send(Sock, [Pkt] ++ ?CRLF);
send_pkg(_, _) ->
    throw("cannot send invalid tcp paquet").

ping(Sock) ->
    send_pkg(Sock, [<<"PING">>]).

auth(Sock, MasterAuth) ->
    send_pkg(Sock, [<<"AUTH">>, ?BS, list_to_binary(MasterAuth)]).

capa(Sock) ->
    send_pkg(Sock, [<<"REPLCONF capa eof">>]).

repl(Sock) ->
    send_pkg(Sock, [<<"REPLCONF listening-port">>, ?BS, get_lport(Sock)]).

sync(Sock) ->
    send_pkg(Sock, [<<"SYNC">>]).

psync(Sock, RunId, Offset) ->
    send_pkg(Sock, [<<"PSYNC">>, ?BS, l2b(RunId), ?BS, i2b(Offset)]).

% Authentication is needed ?.
do_auth(Pass) when length(Pass) > 1 ->
    true;
do_auth(_) ->
    false.

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
    B2 = hd(binary:split(B, ?CRLF)), % First element of binary
    binary_to_integer(B2);
int_offset(_) ->
    throw("error in binary offset").
