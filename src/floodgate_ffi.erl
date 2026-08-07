-module(floodgate_ffi).
-export([now_seconds/0, now_ms/0, getenv/2, setenv/2, secure_compare/2,
         json_encode/1, raw_json/1]).

now_seconds() -> erlang:system_time(second).

%% Monotonic, for measuring elapsed time. Not comparable with now_seconds/0.
now_ms() -> erlang:monotonic_time(millisecond).

getenv(Name, Default) ->
  case os:getenv(binary_to_list(Name)) of
    false -> Default;
    "" -> Default;
    V -> list_to_binary(V)
  end.

%% Set an environment variable for the current node. Exists so tests can
%% exercise env-driven configuration paths (`FLOODGATE_HEARTBEAT_TIMEOUT_MS`)
%% without a second construction API for every knob.
setenv(Name, Value) ->
  true = os:putenv(binary_to_list(Name), binary_to_list(Value)),
  nil.

secure_compare(Left, Right) when byte_size(Left) =:= byte_size(Right) ->
  crypto:hash_equals(Left, Right);
secure_compare(_, _) ->
  false.

json_encode(Value) ->
  iolist_to_binary(json:encode(Value)).

raw_json(Value) ->
  Value.
