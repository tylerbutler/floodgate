%% ETS primitives for the per-document actor registry.
%%
%% Gleam has no process registry, and `process.new_name/1` mints an atom per
%% call — so document ids cannot name actors without filling the atom table.
%% This is the same answer Elixir's `Registry` gives Levee: a public ETS table
%% read directly by the calling process, so resolving a document costs no
%% message hop and there is no global mailbox on the hot path.
%%
%% The table is named after the registry owner's `process.Name` atom, which is
%% already allocated once per instance at startup. That keeps the name stable
%% across an owner restart (the table dies with its owner and is recreated under
%% the same name) without minting anything new, and lets independent sessions —
%% the test suite starts many — coexist on one node.
%%
%% Writes are made by the owner actor (inserts) and by each document actor
%% deleting its own row on shutdown. See `floodgate/doc_registry`.
-module(floodgate_registry_ffi).
-export([table_name/1, new/1, insert/3, lookup/2, delete/2, size/1]).

%% A `process.Name` is already an atom; this only drops its phantom type so the
%% registry can be generic over the value it stores rather than over whatever
%% message type the owner happens to take.
table_name(Name) -> Name.

%% Idempotent: an owner restart recreates the table under the same name, and
%% `ets:new/2` would badarg on a name that already exists.
new(Name) ->
  case ets:whereis(Name) of
    undefined ->
      ets:new(Name, [named_table, set, public, {read_concurrency, true}]),
      nil;
    _ ->
      nil
  end.

insert(Name, Key, Value) ->
  ets:insert(Name, {Key, Value}),
  nil.

lookup(Name, Key) ->
  %% The table is gone only if the owner died and its RestForOne sibling has not
  %% yet restarted it; report that as a miss rather than crashing the caller.
  try ets:lookup(Name, Key) of
    [{_, Value}] -> {ok, Value};
    [] -> {error, nil}
  catch
    error:badarg -> {error, nil}
  end.

delete(Name, Key) ->
  try ets:delete(Name, Key) of
    _ -> nil
  catch
    error:badarg -> nil
  end.

size(Name) ->
  case ets:info(Name, size) of
    undefined -> 0;
    N -> N
  end.
