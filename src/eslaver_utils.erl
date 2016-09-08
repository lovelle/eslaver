-module (eslaver_utils).

-export ([i2l/1, i2b/1, b2l/1, l2b/1]).


%% Short func for 'integer_to_list'
i2l(I) when is_integer(I) ->
    integer_to_list(I).

%% Short func for 'integer_to_binary'
i2b(I) when is_integer(I) ->
    list_to_binary(integer_to_list(I)).

%% Short func for 'binary_to_list'
b2l(B) when is_binary(B) ->
    binary_to_list(B).

%% Short func for 'list_to_binary'
l2b(L) when is_list(L) ->
    list_to_binary(L).
