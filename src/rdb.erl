-module(rdb).
-on_load(init/0).

-export([
    save/3,
    load/2
]).

-define(APPNAME, eslaver).
-define(LIBNAME, rdb).


init() ->
    Bin = case code:priv_dir(?APPNAME) of
        {error, bad_name} ->
            case filelib:is_dir(filename:join(["..", priv])) of
                true ->
                    filename:join(["..", priv, ?LIBNAME]);
                _ ->
                    filename:join([priv, ?LIBNAME])
            end;
        Dir ->
            filename:join(Dir, ?LIBNAME)
    end,
    erlang:load_nif(Bin, 0).


load(_Pid, _File) ->
    not_loaded(?LINE).

save(_Data, _Mode, _File) ->
    not_loaded(?LINE).

not_loaded(Line) ->
    exit({not_loaded, [{module, ?MODULE}, {line, Line}]}).
