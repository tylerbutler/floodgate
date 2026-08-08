//// Static file serving for the shared `server/levee_admin` Lustre SPA under
//// `/admin` and `/admin/*`.
////
//// Serves the same build artifact Levee's `Plug.Static` does — `gleam build
//// --target javascript`'s output plus the SPA's own `index.html` — with no
//// fork of its source. Any request that does not resolve to a real file under
//// the configured directory (including the bare `/admin` path itself) falls
//// back to `index.html`, so the SPA's own client-side router
//// (`levee_admin/router.gleam` + `modem`) handles it — the same SPA-fallback
//// behaviour Phoenix's static plug plus `AdminController.index/2` produce
//// together. See `floodgate/README.md`'s Admin UI section for how the
//// directory gets populated.

import gleam/bytes_tree
import gleam/http/response.{type Response}
import gleam/list
import gleam/option
import gleam/string
import mist

/// Serve `/admin` (`path_parts == []`) or `/admin/<path_parts>` from `dir`.
/// Any failure — a traversal attempt, a missing file, or a path naming a
/// directory — falls back to `index.html` rather than a bare 404, matching
/// the SPA-fallback contract every client-side route under `/admin` needs.
pub fn serve(
  dir: String,
  path_parts: List(String),
) -> Response(mist.ResponseData) {
  case safe_join(dir, path_parts) {
    Error(Nil) -> serve_index(dir)
    Ok(path) ->
      case mist.send_file(path, offset: 0, limit: option.None) {
        Ok(file) ->
          response.new(200)
          |> response.set_header("content-type", content_type_for(path))
          |> response.set_body(file)
        Error(_) -> serve_index(dir)
      }
  }
}

/// Serve `dir <> "/index.html"` — the SPA shell. Used both for `/admin`
/// itself and as the fallback for any unrecognized `/admin/*` path.
fn serve_index(dir: String) -> Response(mist.ResponseData) {
  let path = dir <> "/index.html"
  case mist.send_file(path, offset: 0, limit: option.None) {
    Ok(file) ->
      response.new(200)
      |> response.set_header("content-type", "text/html; charset=utf-8")
      |> response.set_body(file)
    Error(_) ->
      response.new(404)
      |> response.set_header("content-type", "text/plain; charset=utf-8")
      |> response.set_body(
        mist.Bytes(bytes_tree.from_string(
          "Floodgate: admin UI assets not found under "
          <> dir
          <> ". Build them first — see server/floodgate/README.md's Admin UI section.",
        )),
      )
  }
}

/// Join `dir` with `parts`, rejecting any segment that could escape it.
/// `["admin", ..path_parts]`'s `path_parts` are already split on `/` by
/// `request.path_segments`, so a literal `..` is the only escape route left
/// to guard against here.
fn safe_join(dir: String, parts: List(String)) -> Result(String, Nil) {
  case list.all(parts, is_safe_segment) {
    True -> Ok(string.join([dir, ..parts], "/"))
    False -> Error(Nil)
  }
}

fn is_safe_segment(segment: String) -> Bool {
  segment != "" && segment != "." && segment != ".."
}

/// A small, fixed content-type table covering what a Gleam/Lustre JavaScript
/// build actually produces (`.mjs`, `.html`) plus a few common static-asset
/// extensions, for resilience if the SPA ever grows images or a stylesheet
/// file. Unknown extensions fall back to a generic binary type rather than
/// guessing.
fn content_type_for(path: String) -> String {
  case string.split(path, ".") |> list.last {
    Ok("html") -> "text/html; charset=utf-8"
    Ok("js") -> "application/javascript; charset=utf-8"
    Ok("mjs") -> "application/javascript; charset=utf-8"
    Ok("json") -> "application/json"
    Ok("map") -> "application/json"
    Ok("css") -> "text/css; charset=utf-8"
    Ok("svg") -> "image/svg+xml"
    Ok("png") -> "image/png"
    Ok("ico") -> "image/x-icon"
    Ok("txt") -> "text/plain; charset=utf-8"
    Ok("wasm") -> "application/wasm"
    _ -> "application/octet-stream"
  }
}
