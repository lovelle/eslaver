-module(test).
-export([start/0]).

-define(REDIS_SELECTDB, 254).
-define(REDIS_EOF, 255).

start() ->
    % Data = <<53,56,13,10,82,69,68,73,83,48,48,48,54,254,0,0,1,97,1,103,0,1,99,1,100,0,1,100,1,101,0,4,112,101,112,101,4,108,111,108,111,0,3,102,111,111,6,98,97,114,97,115,100,255,46,174,95,163,154,136,39,216>>,
    % Data with db
    % Data = <<36,52,49,13,10,82,69,68,73,83,48,48,48,54,254,4,0,3,102,111,111,3,98,97,114,0,4,104,111,108,97,5,109,117,110,100,111,255,203,123,39,25,238,31,21,97>>,
    % Data with db and list
    Data = <<36,52,57,13,10,82,69,68,73,83,48,48,48,54,254,8,10,4,117,115,101,114,22,22,0,0,0,16,0,0,0,2,0,0,4,106,117,97,110,6,3,101,122,101,255,255,226,19,167,169,160,194,29,1>>,
    [Line, Rest] = binary:split(Data, <<"\r\n">>),
    {ok, Rest1, RdbVer} = parse_rdb_version(Rest),
    {ok, Database, Rest2} = parse(Rest1),
    io:format("~s~n", [Line]),
    io:format("~s~n", [Rest]),
    io:format("-----------~n"),
    io:format("~s~n", [Rest2]),
    io:format("~p~n", [Rest2]).

parse_rdb_version(<<"REDIS", RdbVer:4/binary, Rest/binary>>) ->
    {ok, Rest, binary_to_integer(RdbVer)};
parse_rdb_version(_) ->
    {error, eof}.

parse_rdb_type(<<Type, Rest/binary>>) ->
    {ok, Type, Rest};
parse_rdb_type(_) ->
    exit({error, eof}).

parse(Rest) ->
    {ok, Type, Rest1} = parse_rdb_type(Rest),
    parse(Type, Rest1).

parse(?REDIS_SELECTDB, Rest) ->
    parse_rdb_db(Rest);
parse(_, _) ->
    exit({error, eof}).

parse_rdb_db(<<Database, Rest/binary>>) ->
    {ok, Database, Rest};
parse_rdb_db(_) ->
    exit({error, undef, eof}).
