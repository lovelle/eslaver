-module(rdb).
-on_load(init/0).

-export([
    save/3,
    load/2
]).


init() ->
    Bin = case code:priv_dir(?MODULE) of
        {error, bad_name} ->
            case filelib:is_dir(filename:join(["..", priv])) of
                true ->
                    filename:join(["..", priv, ?MODULE]);
                _ ->
                    filename:join([priv, ?MODULE])
            end;
        Dir ->
            filename:join(Dir, ?MODULE)
    end,
    erlang:load_nif(Bin, 0).


load(_Pid, _File) ->
    not_loaded(?LINE).

save(_Data, _Mode, _File) ->
    not_loaded(?LINE).

not_loaded(Line) ->
    exit({not_loaded, [{module, ?MODULE}, {line, Line}]}).
