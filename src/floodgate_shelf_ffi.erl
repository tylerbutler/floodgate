-module(floodgate_shelf_ffi).
-export([ensure_dir/1, file_exists/1, log_open_failure/2, make_table_public/1, publish_tables/2, lookup_tables/1]).

%% Ensure a directory exists (mkdir -p semantics). filelib:ensure_dir/1 creates
%% all parent directories of the given path, so join a sentinel child to make
%% the whole `Dir` chain exist.
ensure_dir(Dir) ->
  ok = filelib:ensure_dir(filename:join(Dir, "shelf")),
  nil.

%% Whether a document's DETS file is already on disk. Used to answer "does this
%% document exist" without opening it — see floodgate/doc_store:exists, which is
%% reachable from unauthenticated REST paths.
file_exists(Path) ->
  filelib:is_regular(Path).

%% A document table that could not be opened means reads miss and writes are
%% dropped for that one document, which is silent otherwise. Hex-encoded paths
%% cannot escape the data directory, so this is a disk-level problem.
log_open_failure(Topic, Path) ->
  logger:warning("floodgate: could not open document table for ~ts at ~ts", [Topic, Path]),
  nil.

%% Replace a shelf PSet's protected ETS table with a public one so Floodgate can
%% write from session actors and REST handler processes. Analogue of levee's
%% storage_ffi_helpers:make_table_public. Must run in the table owner process
%% (here, whoever calls shelf_store:new). Returns the PSet with the swapped
%% table; the DETS handle and write mode are preserved.
make_table_public(PSet) ->
  OldEts = element(2, PSet),
  Type = proplists:get_value(type, ets:info(OldEts)),
  NewEts = ets:new(shelf_ets, [Type, public, {keypos, 1}, {read_concurrency, true}]),
  ets:foldl(fun(Entry, _) -> ets:insert(NewEts, Entry) end, ok, OldEts),
  ets:delete(OldEts),
  setelement(2, PSet, NewEts).

publish_tables(Name, Tables) ->
  case ets:whereis(Name) of
    undefined ->
      ets:new(Name, [named_table, set, public, {read_concurrency, true}]);
    _ ->
      ok
  end,
  ets:insert(Name, {tables, Tables}),
  nil.

lookup_tables(Name) ->
  try ets:lookup(Name, tables) of
    [{tables, Tables}] -> {ok, Tables};
    [] -> {error, nil}
  catch
    error:badarg -> {error, nil}
  end.
