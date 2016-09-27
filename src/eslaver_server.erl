-module(eslaver_server).
-behaviour(gen_server).

% API calls
-export([start/0, start/1, stop/0]).

% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-define(APP, eslaver).

%% Default settings.
-define(DEFAULT_RDB_FILE, "/tmp/dump_erl.rdb").
-define(DEFAULT_MASTER_HOST, "127.0.0.1").
-define(DEFAULT_MASTER_PORT, 6379).

-define(BS, <<" ">>). % Binary blank space
-define(CRLF, <<"\r\n">>).
-define(BUFFER, 1024). % Default buffer size
-define(EMPTY, <<>>).

%% Heartbeat for psync repl
-define(REPL_TIMEOUT, 1000).

-record(state, {runid="?",
                offset=-1,
                mode,
                state,
                socket,
                buffer=?EMPTY,
                callback}).


%%====================================================================
%% API calls
%%====================================================================
start() ->
    start([]).

start(Callback) ->
    gen_server:start_link({global, ?MODULE}, ?MODULE, [Callback], []).

stop() ->
    gen_server:call({global, ?MODULE}, shutdown).

%%====================================================================
%% gen_server callbacks
%%====================================================================
init([Callback]) ->
    process_flag(trap_exit, true),
    {ok, Cb} = eslaver_utils:get_callback(Callback),
    try initial() of
        {ok, pong, Sock} ->
            gen_server:cast(self(), repl),
            {ok, #state{socket=Sock, state=list, callback=Cb}};
        {error, timeout} ->
            {stop, timeout};
        {error, Reason} ->
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
    handle_sock(repl_listen(Sock), S);

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

%% First step of receiving payload on psync state.
handle_cast(psync, S = #state{state=payload}) ->
    io:format("psync payload ~n"),
    handle_sock(get_payload, S);

%% Buffer
handle_cast({save_rdb, Bulk, Mode}, S = #state{state=buffering}) ->
    io:format("buffered data ~n"),
    ok = rdb_save(Bulk, Mode),
    handle_sock(get_buffered, S);

%% RDB SAVE
handle_cast({save_rdb, Bulk, Mode}, S = #state{state=payload}) ->
    io:format("save_rdb data ~n"),
    ok = rdb_save(Bulk, Mode), % Fixme, rdb_save parse can be '{error, Reason}'
    gen_server:cast(self(), {load_rdb, self()}),
    {noreply, S};

%% RDB LOAD
handle_cast({load_rdb, Pid}, S = #state{state=payload}) ->
    io:format("load_rdb data: ~p ~n", [Pid]),
    ok = rdb_load(Pid), % Fixme, rdb_load parse can be '{error, Reason}'
    gen_server:cast(self(), replication), % Move this to eof handle_info
    {noreply, S#state{state=stream}};

%% Stream replication for sync mode
handle_cast(replication, S = #state{socket=Sock, state=stream, mode=sync}) ->
    inet:setopts(Sock, [{active,once}]),
    {noreply, S};

%% Stream replication for psync mode
handle_cast(replication, S = #state{socket=Sock, state=stream, mode=psync}) ->
    inet:setopts(Sock, [{active,once}]),
    {noreply, S, ?REPL_TIMEOUT};

%% Reconnect to master server
handle_cast(new_connection, S = #state{state=reconnect}) ->
    %% BUG! Take care if master is not able to receive connections
    {ok, pong, NewSock} = initial(), % FIXME !
    gen_server:cast(self(), repl),
    {noreply, S#state{socket=NewSock, state=reconnect2}};
handle_cast(repl, S = #state{socket=Sock, state=reconnect2}) ->
    % timer:sleep(20000),
    handle_sock(repl_listen(Sock), S);
handle_cast(bar, S = #state{mode=Type, state=reconnect3}) -> % FIXME
    gen_server:cast(self(), Type),
    {noreply, S#state{state=load}};

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

handle_info({loading, eof}, S) ->
    eslaver_utils:callback(S#state.callback, [{loading, eof}]),
    {noreply, S};
handle_info({loading, T, K, V}, S) -> % Type, Key, Value
    eslaver_utils:callback(S#state.callback, [{loading, T, K, V}]),
    {noreply, S};

handle_info({tcp, Sock, Data}, S = #state{state=stream, mode=sync, buffer=Buffer}) ->
    case buffer(byte_size(Data), Data, Buffer) of
        {ok, NewBuffer} ->
            ok;
        {ok, NewBuffer, Commands, _} ->
            eslaver_utils:callback(S#state.callback, Commands)
    end,
    inet:setopts(Sock, [{active,once}]),
    {noreply, S#state{buffer=NewBuffer}};

handle_info({tcp, Sock, Data}, S = #state{state=stream, mode=psync, buffer=Buffer}) ->
    NewOffset = case buffer(byte_size(Data), Data, Buffer) of
        {ok, NewBuffer} ->
            S#state.offset;
        {ok, NewBuffer, Commands, OffsetSize} ->
            eslaver_utils:callback(S#state.callback, Commands),
            (S#state.offset + OffsetSize)
    end,
    %repl_ack(Sock, NewOffset), % still don't know if putting this here is a good idea
    inet:setopts(Sock, [{active,once}]),
    {noreply, S#state{offset=NewOffset, buffer=NewBuffer}, ?REPL_TIMEOUT};

%% Psync mode need to send offset data periodically
%% in order to maintain the slavery active in socket.
handle_info(timeout, S = #state{socket=Sock, offset=Offset, mode=psync, state=stream}) ->
    repl_ack(Sock, Offset),
    {noreply, S, ?REPL_TIMEOUT};

%% Tcp connection closed from master
handle_info({tcp_closed, Sock}, S) ->
    io:format("tcp connection closed from master '~p' ~n", [S]),
    gen_tcp:close(S#state.socket),
    gen_tcp:close(Sock),
    gen_server:cast(self(), new_connection),
    {noreply, S#state{state=reconnect}};
handle_info({tcp_error, _Sock, Reason}, S) ->
    io:format("tcp connection error from master '~p' ~n", [S]),
    {stop, Reason};
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

handle_sock(ok, S = #state{socket=Sock, state=reconnect2}) ->
    case recv_sock(Sock) of
        {ok, _} ->
            gen_server:cast(self(), bar),
            {noreply, S#state{state=reconnect3}};
        {error, Reason} ->
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

handle_sock(get_buffered, S = #state{socket=Sock, state=buffering}) ->
    io:format("getting payload buffer ~n"),
    handle_recv(recv_sock(Sock), S);

handle_sock({error, Reason}, S) ->
    {stop, socket_err, {S, Reason}};
handle_sock(_,_) ->
    {stop, general, "general socket error"}.

handle_recv({ok, continue, Data}, S) ->
    self() ! {tcp, S#state.socket, Data},
    gen_server:cast(self(), replication),
    {noreply, S#state{state=stream}};
handle_recv({ok, fullresync, RunId, Offset}, S) ->
    gen_server:cast(self(), psync),
    {noreply, S#state{state=payload, runid=RunId, offset=Offset}};

%%
%% Handle load from streaming payload
%%

%% Sync load mode
handle_recv({ok, load_stream, Bulk}, S = #state{state=load}) ->
    gen_server:cast(self(), {save_rdb, Bulk, 0}),
    {noreply, S#state{state=payload}};
%% Psync load mode
handle_recv({ok, load_stream, Bulk}, S = #state{state=payload}) ->
    gen_server:cast(self(), {save_rdb, Bulk, 0}),
    {noreply, S};
handle_recv({ok, load_stream, Bulk}, S = #state{state=buffering}) ->
    gen_server:cast(self(), {save_rdb, Bulk, 1}),
    {noreply, S#state{state=payload}};

%%
%% Handle load from buffered payload
%%

%% Sync buffer mode
handle_recv({ok, load_buffer, Bulk}, S = #state{state=load}) ->
    gen_server:cast(self(), {save_rdb, Bulk, 0}),
    {noreply, S#state{state=buffering}};
%% Psync buffer mode
handle_recv({ok, load_buffer, Bulk}, S = #state{state=payload}) ->
    gen_server:cast(self(), {save_rdb, Bulk, 0}),
    {noreply, S#state{state=buffering}};
handle_recv({ok, load_buffer, Bulk}, S = #state{state=buffering}) ->
    gen_server:cast(self(), {save_rdb, Bulk, 1}),
    {noreply, S};

handle_recv({error, Reason}, S) ->
    {stop, socket_err, {S, Reason}};
handle_recv(_, _) ->
    {stop, invalid_pmatch}.


initial() ->
    Addr = config(master_host, ?DEFAULT_MASTER_HOST),
    Port = config(master_port, ?DEFAULT_MASTER_PORT),
    Pass = config(master_auth, undef),
    Sock = case inet_parse:address(Addr) of
        {ok, Host} ->
            connect(Host, Port);
        {error, Error} ->
            Error
    end,

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
        % "+CONTINUE"
        {tcp, _Sock, <<"+OK", _/binary>>} ->
            {ok, psync};
        {tcp, Sock, <<"+PONG", _/binary>>} ->
            {ok, pong, Sock};
        {tcp, _Sock, <<"+CONTINUE", _, _, Data/binary>>} ->
            {ok, continue, Data};
        {tcp, _Sock, <<"+FULLRESYNC", _, RunId:40/binary, _, Offset/binary>>} ->
            {ok, fullresync, eslaver_utils:b2l(RunId), int_offset(Offset)};
        {tcp, _Sock, <<"-ERR Unrecognized REPLCONF", _/binary>>} ->
            {ok, sync};
        {tcp, _Sock, <<"-", Error/binary>>} ->
            {error, Error};
        {tcp, _Sock, <<Bulk/binary>>} ->
            case byte_size(Bulk) of
                ?BUFFER ->
                    {ok, load_buffer, Bulk};
                _ ->
                    {ok, load_stream, Bulk}
            end;
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
    gen_tcp:connect(Addr, Port, [binary, {active, false}, {buffer, ?BUFFER}]).

rdb_load(Pid) when is_pid(Pid) ->
    RdbFile = config(dbfilename, ?DEFAULT_RDB_FILE),
    rdb:load(Pid, RdbFile);
rdb_load(_) ->
    {error, "invalid pid to load rdb"}.

rdb_save(Data, Mode) when is_binary(Data), Mode >= 0, Mode =< 1 ->
    RdbFile = config(dbfilename, ?DEFAULT_RDB_FILE),
    rdb:save(Data, Mode, RdbFile);
rdb_save(_, _) ->
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

repl_listen(Sock) ->
    send_pkg(Sock, [<<"REPLCONF listening-port">>, ?BS, local_port(Sock)]).

repl_ack(Sock, Offset) when is_integer(Offset) ->
    % "*3\r\n$8\r\nREPLCONF\r\n$3\r\nACK\r\n$%d\r\n%s\r\n"
    OffSize = byte_size(eslaver_utils:i2b(Offset)), %% Offset size
    BOffset = eslaver_utils:i2b(Offset),
    Repl = [redis:rlen(3), ?CRLF, redis:rsize(8), ?CRLF, <<"REPLCONF">>, ?CRLF,
            redis:rsize(3),?CRLF, <<"ACK">>,?CRLF, redis:rsize(OffSize), ?CRLF, BOffset],
    send_pkg(Sock, Repl).

sync(Sock) ->
    send_pkg(Sock, [<<"SYNC">>]).

psync(Sock, RunId, Offset) ->
    send_pkg(Sock, [<<"PSYNC">>, ?BS, eslaver_utils:l2b(RunId),
                    ?BS, eslaver_utils:i2b(Offset)]).

% Authentication is needed ?.
do_auth(Pass) when length(Pass) > 1 ->
    true;
do_auth(_) ->
    false.

%% Get client listen port in binary format
local_port(Sock) ->
    {ok, Port} = inet:port(Sock),
    eslaver_utils:i2b(Port).

%% Convert -> <<"666\r\n">> to normal integer
int_offset(B) when is_binary(B) ->
    B2 = hd(binary:split(B, ?CRLF)), % First element of binary
    binary_to_integer(B2);
int_offset(_) ->
    throw("error in binary offset").

%% Get config
config(Key, Default) ->
    case application:get_env(?APP, Key) of
        undefined -> Default;
        {ok, Val} -> Val
    end.

buffer(0, ?EMPTY, ?EMPTY) ->
    {ok, ?EMPTY};
buffer(1, <<"\n">>, ?EMPTY) ->
    {ok, ?EMPTY};
buffer(?BUFFER, Data, Buffer) ->
    {ok, bufferize(Data, Buffer)};
buffer(A, Data, Buffer) ->
    io:format("mira -> ~p ~p ~p ~n",[A, Data, Buffer]),
    NewData = <<Buffer/binary, Data/binary>>,
    {ok, Commands} = redis:parse(NewData), % FIXME
    {ok, ?EMPTY, Commands, byte_size(NewData)}.

bufferize(Data, ?EMPTY) ->
    Data;
bufferize(Data, Buffer) ->
    <<Buffer/binary, Data/binary>>.
