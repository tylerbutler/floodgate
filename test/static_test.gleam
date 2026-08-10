import floodgate/static
import gleam/bit_array
import gleam/crypto
import gleam/http/response
import gleeunit/should

@external(erlang, "static_test_ffi", "write_file")
fn write_file(path: String, content: String) -> Nil

/// A fresh, unique on-disk directory per test, so runs never see another
/// test's (or a previous run's) files. Lives under `build/`, which is
/// gitignored and cleaned by `gleam clean` — see `tenant_store_test.unique_dir`
/// for the same pattern applied to shelf's DETS directories.
fn unique_dir() -> String {
  "build/floodgate_static_test/"
  <> { crypto.strong_random_bytes(8) |> bit_array.base16_encode }
}

pub fn serves_a_real_file_with_a_matching_content_type_test() {
  let dir = unique_dir()
  write_file(dir <> "/index.html", "<html>shell</html>")
  write_file(dir <> "/levee_admin/levee_admin.mjs", "export {}")

  let served_response = static.serve(dir, ["levee_admin", "levee_admin.mjs"])
  served_response.status |> should.equal(200)
  response.get_header(served_response, "content-type")
  |> should.equal(Ok("application/javascript; charset=utf-8"))
}

pub fn serves_index_html_for_the_bare_admin_path_test() {
  let dir = unique_dir()
  write_file(dir <> "/index.html", "<html>shell</html>")

  let served_response = static.serve(dir, [])
  served_response.status |> should.equal(200)
  response.get_header(served_response, "content-type")
  |> should.equal(Ok("text/html; charset=utf-8"))
}

/// Any client-side route under `/admin` — e.g. `/admin/dashboard` — is not a
/// real file, and must fall back to the SPA shell so `modem`'s router can
/// handle it, exactly like Phoenix's static plug plus `AdminController.index/2`
/// do together for Levee.
pub fn falls_back_to_index_html_for_an_spa_route_test() {
  let dir = unique_dir()
  write_file(dir <> "/index.html", "<html>shell</html>")

  let served_response = static.serve(dir, ["dashboard"])
  served_response.status |> should.equal(200)
  response.get_header(served_response, "content-type")
  |> should.equal(Ok("text/html; charset=utf-8"))
}

pub fn falls_back_to_index_html_for_a_nested_spa_route_test() {
  let dir = unique_dir()
  write_file(dir <> "/index.html", "<html>shell</html>")

  let served_response = static.serve(dir, ["tenants", "abc-123"])
  served_response.status |> should.equal(200)
  response.get_header(served_response, "content-type")
  |> should.equal(Ok("text/html; charset=utf-8"))
}

/// A `..` segment must never escape the configured directory — it falls back
/// to `index.html` exactly like any other path that does not name a real file
/// under `dir`, rather than reading whatever a traversal reached.
pub fn rejects_path_traversal_by_falling_back_to_index_test() {
  let dir = unique_dir()
  write_file(dir <> "/index.html", "<html>shell</html>")
  // A sentinel file outside `dir`, which a successful traversal would reach.
  write_file(dir <> "/../secret.txt", "top secret")

  let served_response = static.serve(dir, ["..", "secret.txt"])
  served_response.status |> should.equal(200)
  response.get_header(served_response, "content-type")
  |> should.equal(Ok("text/html; charset=utf-8"))
}

pub fn rejects_a_traversal_segment_buried_in_a_longer_path_test() {
  let dir = unique_dir()
  write_file(dir <> "/index.html", "<html>shell</html>")
  write_file(dir <> "/../secret.txt", "top secret")

  let served_response =
    static.serve(dir, ["levee_admin", "..", "..", "secret.txt"])
  served_response.status |> should.equal(200)
  response.get_header(served_response, "content-type")
  |> should.equal(Ok("text/html; charset=utf-8"))
}

/// With no assets built at all (no `index.html` either), the fallback itself
/// has nothing to serve — a 404 with a build hint, not a crash.
pub fn returns_404_with_a_build_hint_when_no_assets_exist_test() {
  let dir = unique_dir()
  let served_response = static.serve(dir, [])
  served_response.status |> should.equal(404)
}

pub fn distinguishes_content_types_by_extension_test() {
  let dir = unique_dir()
  write_file(dir <> "/index.html", "<html>shell</html>")
  write_file(dir <> "/gleam_stdlib/gleam.mjs", "export {}")

  let served_response = static.serve(dir, ["gleam_stdlib", "gleam.mjs"])
  response.get_header(served_response, "content-type")
  |> should.equal(Ok("application/javascript; charset=utf-8"))
}
