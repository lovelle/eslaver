-module (eslaver_utils).

-export ([i2b/1, i2l/1, b2l/1, b2i/1, l2b/1,
          callback/2, get_callback/1]).

-define(APP, eslaver).


%% Shortcut fun for 'integer_to_binary'
i2b(I) when is_integer(I) ->
    l2b(i2l(I)).

%% Shortcut fun for 'integer_to_list'
i2l(I) when is_integer(I) ->
    integer_to_list(I).

%% Shortcut fun for 'binary_to_list'
b2l(B) when is_binary(B) ->
    binary_to_list(B).

%% Shortcut fun for 'binary_num_to_integer'
b2i(B) when is_binary(B) ->
    list_to_integer(b2l(B)).

%% Shortcut fun for 'list_to_binary'
l2b(L) when is_list(L) ->
    list_to_binary(L).


%% Do Callback call to what the user has defined.
callback({M, F}, Cmds) when is_atom(M), is_atom(F) ->
    [apply(M, F, [X]) || X <- Cmds];

callback({M, F, A}, Cmds) when is_atom(M), is_atom(F), is_list(A) ->
    [apply(M, F, A ++ [X]) || X <- Cmds];

callback(F, Cmds) when is_function(F) ->
    [apply(F, [X]) || X <- Cmds];

callback(Pid, Cmds) when is_pid(Pid) ->
    [Pid ! X || X <- Cmds];

callback(_, _) ->
    {error, invalid_callback}.

%% Get valid callbacks
get_callback({M, F}) when is_atom(M), is_atom(F) ->
    {ok, {M, F}};
get_callback({M, F, A}) when is_atom(M), is_atom(F), is_list(A) ->
    {ok, {M, F, A}};
get_callback(F) when is_function(F) ->
    {ok, F};
get_callback([]) ->
    F = fun(X) -> io:format("~s -> ~p~n", [?APP, X]) end,
    {ok, F};
get_callback(Pid) when is_pid(Pid) ->
    [State|_] = [Status || {status, Status} <- process_info(Pid)],
    case State of
        waiting ->
            {ok, Pid};
        _ ->
            {error, invalid_pid_state}
    end;
get_callback(_) ->
    {error, invalid_callback}.
