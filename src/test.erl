-module(test).
-export([start/0, client/1, server/1, process/1]).


start() ->
    Pid = spawn(?MODULE, server, [self()]),
    client(Pid),
    process(Pid).


client(Pid) ->
    Data = <<36,49,56,54,13,10,82,69,68,73,83,48,48,48,54,254,0,13,5,117,115,101,
            114,115,64,73,73,0,0,0,64,0,0,0,10,0,0,4,110,97,109,101,6,8,69,122,
            101,113,117,105,101,108,10,3,97,103,101,5,254,22,3,4,99,105,116,121,
            6,6,66,101,114,108,105,110,8,2,99,112,4,192,15,39,4,6,102,97,116,104,
            101,114,8,6,68,97,110,105,101,108,255,10,6,109,121,108,105,115,116,
            32,32,0,0,0,26,0,0,0,9,0,0,249,2,242,2,243,2,244,2,245,2,246,2,247,2,
            248,2,3,102,111,111,255,0,3,102,111,111,3,98,97,114,12,6,109,121,122,
            115,101,116,25,25,0,0,0,22,0,0,0,4,0,0,3,111,110,101,5,242,2,3,117,
            110,111,5,242,255,255,25,120,128,60,72,122,38,183>>,
    rdb:save(Data),
    rdb:load(Pid).


process(Pid) ->
    receive
        {_From, loading, Type, <<Key/binary>>, _Rest} ->
            io:format("key type '~s' is -> '~s' ~n", [Type, Key]),
            process(Pid);
        {_From, eof} ->
            io:format("eof ~n")
    end.


server(From) ->
    receive
        {loading, _Type, _Key, _Rest} ->
            From ! {self(), loading, _Type, _Key, _Rest},
            server(From);
        {loading, eof} ->
            From ! {self(), eof}
    end.
