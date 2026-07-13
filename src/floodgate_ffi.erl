-module(floodgate_ffi).
-export([now_seconds/0, getenv/2, secure_compare/2, json_encode/1, raw_json/1]).

now_seconds() -> erlang:system_time(second).

getenv(Name, Default) ->
  case os:getenv(binary_to_list(Name)) of
    false -> Default;
    "" -> Default;
    V -> list_to_binary(V)
  end.

secure_compare(Left, Right) when byte_size(Left) =:= byte_size(Right) ->
  crypto:hash_equals(Left, Right);
secure_compare(_, _) ->
  false.

json_encode(Value) ->
  iolist_to_binary(json:encode(Value)).

raw_json(Value) ->
  Value.
