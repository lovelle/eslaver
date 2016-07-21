-module(rdb).
-on_load(init/0).

-export([
    rdb/1, rdb/0,
    rdb2/2,
    double/1,
    triple_defer/1,
    triple_direct/1
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


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
rdb(_N) ->
    not_loaded(?LINE).
rdb() ->
    not_loaded(?LINE).

rdb2(_N, _D) ->
    not_loaded(?LINE).
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

double(_N) ->
    not_loaded(?LINE).


triple_defer(_N) ->
    not_loaded(?LINE).


triple_direct(_N) ->
    not_loaded(?LINE).


not_loaded(Line) ->
    exit({not_loaded, [{module, ?MODULE}, {line, Line}]}).
