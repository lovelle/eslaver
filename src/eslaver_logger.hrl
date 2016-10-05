-define(LOGGING(LEVEL, FMT, ARGS),
        "~s [~s] " ++ FMT ++ " ~n", [time_fmt(), LEVEL | ARGS]).

-define(DEBUG(Format, Args),
        io:format(?LOGGING("debug", Format, Args))).
-define(INFO(Format, Args),
        io:format(?LOGGING("info", Format, Args))).
-define(WARN(Format, Args),
        io:format(?LOGGING("warn", Format, Args))).
-define(ERR(Format, Args),
		error_logger:error_msg(?LOGGING("error", Format, Args))).

time_fmt() ->
    {H, M, S} = time(),
    {_, _, Micro} = os:timestamp(),
    io_lib:format('~2..0b:~2..0b:~2..0b.~6..0b', [H, M, S, Micro]).
