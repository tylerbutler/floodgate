-module(floodgate_shelf_ffi).
-export([ensure_dir/1, make_table_public/1]).

%% Ensure a directory exists (mkdir -p semantics). filelib:ensure_dir/1 creates
%% all parent directories of the given path, so join a sentinel child to make
%% the whole `Dir` chain exist.
ensure_dir(Dir) ->
  ok = filelib:ensure_dir(filename:join(Dir, "shelf")),
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
