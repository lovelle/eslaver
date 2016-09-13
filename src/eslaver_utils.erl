-module (eslaver_utils).

-export ([i2b/1, i2l/1, b2l/1, b2i/1, l2b/1]).


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
