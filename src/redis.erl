-module(redis).

-define(CRLF, "\r\n").

-export([rsize/1, rlen/1, parse/1]).


%%
%% Redis protocol funcs
%%

%% Short func to redis proto size element.
%% -> <<"$1">>.
rsize(N) when is_integer(N) ->
    redis_int2bin(36, N);
rsize(_) ->
    error.

%% Short func to redis proto length element.
%% -> <<"*1">>
rlen(N) when is_integer(N) ->
    redis_int2bin(42, N);
rlen(_) ->
    error.

redis_int2bin(Char, N) ->
    S = [Char, eslaver_utils:i2l(N)],
    eslaver_utils:l2b(S).

% redis:parse(<<"*2\r\n$6\r\nSELECT\r\n$1\r\n0\r\n*3\r\n$3\r\nset\r\n$3\r\nfoo\r\n$3\r\nbar\r\n">>)
parse(Bin) when is_binary(Bin) ->
    parse_multibulk(Bin, []);
parse(_) ->
    {error, invalid_input}.


parse_multibulk(<<>>, Acc) ->
    {ok, <<>>, Acc};
parse_multibulk(<<"*", Rest/binary>>, Acc) ->
    handle_bulk(multi, Acc, parse_head(Rest, <<>>));
parse_multibulk(A,B) ->
    io:format("A -> ~p B -> ~p ~n", [A,B]),
    {error, protocol_mismatch}.


parse_bulk(<<"$", Rest/binary>>, CmdLen, Acc) ->
    handle_bulk(short, {Acc, CmdLen}, parse_head(Rest, <<>>));
parse_bulk(<<Rest/binary>>, 0, Acc) ->
    Lst = lists:reverse(Acc),
    Cmd = eslaver_utils:b2l(hd(Lst)),
    Key = string:to_lower(Cmd),
    {ok, bulk, {cmd, Key, tl(Lst)}, Rest};
parse_bulk(_, _, _) ->
    {error, protocol_mismatch}.


handle_bulk(multi, Acc, {ok, head, CmdLen, Command}) ->
    Size = eslaver_utils:b2i(CmdLen),
    bulk(multi, {Acc}, parse_bulk(Command, Size, []));
handle_bulk(short, {Acc, CmdLen}, {ok, head, CmdSize, Command}) ->
    Size = eslaver_utils:b2i(CmdSize),
    bulk(short, {Acc, CmdLen}, parse_str(Command, Size));
handle_bulk(_, _, {error, Reason}) ->
    {error, Reason} .


bulk(multi, {Acc}, {ok, bulk, X, <<>>}) ->
    {ok, lists:reverse([X|Acc])};
bulk(multi, {Acc}, {ok, bulk, X, Rest}) ->
    parse_multibulk(Rest, [X|Acc]);
bulk(short, {Acc, CmdLen}, {ok, parse, Cmd, Rest}) ->
    parse_bulk(Rest, CmdLen - 1, [Cmd|Acc]);
bulk(_, _, {error, Reason}) ->
    {error, Reason}.


parse_head(<<?CRLF, Rest/binary>>, Acc) ->
    {ok, head, Acc, Rest};
parse_head(<<Str, Rest/binary>>, Acc) ->
    parse_head(Rest, <<Acc/binary, Str>>);
parse_head(<<>>, _) ->
    {error, empty_stream}.


parse_str(Data, Size) when size(Data) > Size ->
    case Data of
        <<Cmd:Size/binary, ?CRLF, Rest/binary>> ->
            {ok, parse, Cmd, Rest};
        _ ->
            {error, invalid_input}
    end;
parse_str(A,B) ->
    io:format("A -> ~p B -> ~p ~n", [A, B]),
    {error, invalid_input}.
