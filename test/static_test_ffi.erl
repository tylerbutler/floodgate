%% Test-only helper for `static_test.gleam`: writing fixture files to a
%% throwaway directory under `build/` (gitignored, cleaned by `gleam clean`).
%% Mirrors the test-scoped FFI pattern beryl's own test suite uses
%% (`beryl_supervisor_test_ffi.erl`) rather than adding a filesystem-writing
%% dependency (e.g. `simplifile`) purely for test fixtures.
-module(static_test_ffi).
-export([write_file/2]).

write_file(Path, Content) ->
  ok = filelib:ensure_dir(Path),
  ok = file:write_file(Path, Content),
  nil.
