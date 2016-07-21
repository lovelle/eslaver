-module(lzf).
-export([unzip/1, unzip/2]).

-on_load(init/0).
-define(LZF_LIB, "./priv/lib_lzf").


init() ->
    case load_nif(default_lzf) of
	ok -> ok;
	{error, {load_failed, _Reason}} ->
           load_nif(lookup_lzf);
	_ -> {error, generic}
    end.

load_nif(default_lzf) ->
    erlang:load_nif(?LZF_LIB, 0);
load_nif(lookup_lzf) ->
    Dir = code:lib_dir(eslaver),
    File = filename:join([Dir, "priv", "lib_lzf"]);
%    erlang:load_nif("search_lib", 0);
load_nif(_) ->
    invalid_action.

unzip(_X) ->
    exit(nzf_nif_not_loaded).

unzip(_X, _Y) ->
    exit(nzf_nif_not_loaded).
