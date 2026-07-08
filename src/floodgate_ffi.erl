-module(floodgate_ffi).
-export([now_seconds/0, getenv/2]).

now_seconds() -> erlang:system_time(second).

getenv(Name, Default) ->
  case os:getenv(binary_to_list(Name)) of
    false -> Default;
    "" -> Default;
    V -> list_to_binary(V)
  end.
