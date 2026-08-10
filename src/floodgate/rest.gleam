//// Pure REST response-shape decisions for the Storage/Historian-style HTTP
//// surface (`POST /documents/:tenant`, `GET /documents/:tenant/:id`,
//// `GET /documents/:tenant/session/:id`, `GET /deltas/:tenant/:id`,
//// `/repos/:tenant/git/*`). Analogue of levee's `DocumentController`,
//// `DeltaController`, and `GitController` private formatting helpers.
////
//// These functions only decide *shape* (URLs, wire field names, which
//// optional fields are present) from plain values the caller already has —
//// they do not touch storage, JWTs, or Plug/Conn. Levee's Phoenix
//// controllers keep doing the actual storage calls and HTTP plumbing, and
//// delegate the response-shape decision to these functions through
//// `Levee.Floodgate`, the same pattern used for Socket.IO framing and
//// document-session decisions.

import gleam/dynamic.{type Dynamic}
import gleam/int
import gleam/list
import gleam/string

/// An arbitrary JSON-shaped BEAM term — a value the (Elixir) caller already
/// decoded, or will encode, with its own JSON library — carried through these
/// response shapes untouched. A dedicated type rather than `Dynamic` so the
/// signatures say exactly what crosses this FFI boundary.
pub type JsonTerm

/// Mark a dynamic value as a `JsonTerm`. Runtime identity — the distinction
/// exists only at compile time, so Elixir callers pass their terms unchanged.
@external(erlang, "floodgate_ffi", "identity")
pub fn json_term(value: Dynamic) -> JsonTerm

/// The reverse boundary crossing, for callers that need to inspect a term.
@external(erlang, "floodgate_ffi", "identity")
pub fn json_term_to_dynamic(value: JsonTerm) -> Dynamic

fn term_string(value: String) -> JsonTerm {
  json_term(dynamic.string(value))
}

fn term_int(value: Int) -> JsonTerm {
  json_term(dynamic.int(value))
}

fn term_bool(value: Bool) -> JsonTerm {
  json_term(dynamic.bool(value))
}

fn term_nil() -> JsonTerm {
  json_term(dynamic.nil())
}

fn term_list(values: List(JsonTerm)) -> JsonTerm {
  json_term(dynamic.list(list.map(values, json_term_to_dynamic)))
}

fn term_properties(entries: List(#(String, JsonTerm))) -> JsonTerm {
  json_term(
    dynamic.properties(
      list.map(entries, fn(entry) {
        #(dynamic.string(entry.0), json_term_to_dynamic(entry.1))
      }),
    ),
  )
}

// ─────────────────────────────────────────────────────────────────────────────
// Base URL / git object URL construction
// ─────────────────────────────────────────────────────────────────────────────

/// Build the scheme://host[:port] prefix, omitting the port for the
/// scheme's default (80 for http, 443 for https).
pub fn base_url(scheme: String, host: String, port: Int) -> String {
  let port_suffix = case scheme, port {
    "http", 80 -> ""
    "https", 443 -> ""
    _, p -> ":" <> int.to_string(p)
  }
  scheme <> "://" <> host <> port_suffix
}

pub fn blob_url(base_url: String, tenant_id: String, sha: String) -> String {
  base_url <> "/repos/" <> tenant_id <> "/git/blobs/" <> sha
}

pub fn tree_url(base_url: String, tenant_id: String, sha: String) -> String {
  base_url <> "/repos/" <> tenant_id <> "/git/trees/" <> sha
}

pub fn commit_url(base_url: String, tenant_id: String, sha: String) -> String {
  base_url <> "/repos/" <> tenant_id <> "/git/commits/" <> sha
}

/// The "refs/" prefix is stripped for the URL (e.g. `refs/heads/main`
/// becomes `.../git/refs/heads/main`).
pub fn ref_url(
  base_url: String,
  tenant_id: String,
  ref_path: String,
) -> String {
  let path = case string.starts_with(ref_path, "refs/") {
    True -> string.drop_start(ref_path, 5)
    False -> ref_path
  }
  base_url <> "/repos/" <> tenant_id <> "/git/refs/" <> path
}

/// Join wildcard-route ref path segments (from `GET/PATCH .../refs/*ref`)
/// into a full `refs/...` path.
pub fn build_ref_path(ref_parts: List(String)) -> String {
  "refs/" <> string.join(ref_parts, "/")
}

// ─────────────────────────────────────────────────────────────────────────────
// Git object response shaping
// ─────────────────────────────────────────────────────────────────────────────

pub fn format_blob_response(
  base_url: String,
  tenant_id: String,
  sha: String,
  size: Int,
  content_base64: String,
) -> List(#(String, JsonTerm)) {
  [
    #("sha", term_string(sha)),
    #("size", term_int(size)),
    #("content", term_string(content_base64)),
    #("encoding", term_string("base64")),
    #("url", term_string(blob_url(base_url, tenant_id, sha))),
  ]
}

/// One entry of a tree's `tree` array: `#(path, mode, sha, type)`.
pub type TreeEntryIn =
  #(String, String, String, String)

fn format_tree_entry(
  base_url: String,
  tenant_id: String,
  entry: TreeEntryIn,
) -> JsonTerm {
  let #(path, mode, sha, entry_type) = entry

  let entry_url = case entry_type {
    "blob" -> term_string(blob_url(base_url, tenant_id, sha))
    "tree" -> term_string(tree_url(base_url, tenant_id, sha))
    _ -> term_nil()
  }

  term_properties([
    #("path", term_string(path)),
    #("mode", term_string(mode)),
    #("sha", term_string(sha)),
    #("type", term_string(entry_type)),
    #("url", entry_url),
  ])
}

pub fn format_tree_response(
  base_url: String,
  tenant_id: String,
  sha: String,
  entries: List(TreeEntryIn),
) -> List(#(String, JsonTerm)) {
  let formatted_entries =
    list.map(entries, format_tree_entry(base_url, tenant_id, _))

  [
    #("sha", term_string(sha)),
    #("url", term_string(tree_url(base_url, tenant_id, sha))),
    #("tree", term_list(formatted_entries)),
  ]
}

pub fn format_commit_response(
  base_url: String,
  tenant_id: String,
  sha: String,
  tree_sha: String,
  parents: List(String),
  message: JsonTerm,
  author: JsonTerm,
  committer: JsonTerm,
) -> List(#(String, JsonTerm)) {
  let tree_obj =
    term_properties([
      #("sha", term_string(tree_sha)),
      #("url", term_string(tree_url(base_url, tenant_id, tree_sha))),
    ])

  let formatted_parents =
    list.map(parents, fn(parent_sha) {
      term_properties([
        #("sha", term_string(parent_sha)),
        #("url", term_string(commit_url(base_url, tenant_id, parent_sha))),
      ])
    })

  [
    #("sha", term_string(sha)),
    #("tree", tree_obj),
    #("parents", term_list(formatted_parents)),
    #("message", message),
    #("author", author),
    #("committer", committer),
    #("url", term_string(commit_url(base_url, tenant_id, sha))),
  ]
}

pub fn format_ref_response(
  base_url: String,
  tenant_id: String,
  ref_path: String,
  sha: String,
) -> List(#(String, JsonTerm)) {
  let object =
    term_properties([
      #("sha", term_string(sha)),
      #("type", term_string("commit")),
      #("url", term_string(commit_url(base_url, tenant_id, sha))),
    ])

  [
    #("ref", term_string(ref_path)),
    #("object", object),
    #("url", term_string(ref_url(base_url, tenant_id, ref_path))),
  ]
}

// ─────────────────────────────────────────────────────────────────────────────
// Document / session response shaping
// ─────────────────────────────────────────────────────────────────────────────

pub fn format_document_response(
  id: String,
  tenant_id: String,
  sequence_number: Int,
) -> List(#(String, JsonTerm)) {
  [
    #("id", term_string(id)),
    #("tenantId", term_string(tenant_id)),
    #("sequenceNumber", term_int(sequence_number)),
  ]
}

/// Build the `GET /documents/:tenant/session/:id` response shape.
pub fn session_info(
  host: String,
  tenant_id: String,
  document_id: String,
  is_alive: Bool,
) -> List(#(String, JsonTerm)) {
  [
    #("ordererUrl", term_string(host <> "/socket")),
    #("historianUrl", term_string(host <> "/repos/" <> tenant_id)),
    #(
      "deltaStreamUrl",
      term_string(host <> "/deltas/" <> tenant_id <> "/" <> document_id),
    ),
    #("isSessionAlive", term_bool(is_alive)),
    #("isSessionActive", term_bool(is_alive)),
  ]
}

// ─────────────────────────────────────────────────────────────────────────────
// Delta (operation history) response shaping
// ─────────────────────────────────────────────────────────────────────────────

/// System messages (join/leave) carry a JSON-stringified `data` field
/// alongside `contents`, matching the Fluid `ISequencedDocumentMessage`
/// wire shape. Levee's `DeltaController` decides whether to attach `data`
/// by asking this function, then does the actual JSON encoding itself
/// (it already depends on Jason for that).
pub fn requires_data_field(msg_type: String) -> Bool {
  msg_type == "join" || msg_type == "leave"
}

/// Build a single `ISequencedDocumentMessage` for `GET /deltas/:tenant/:id`.
/// `data` should be `Some(json_string)` when `requires_data_field` is
/// `True` for `msg_type`, and `None` otherwise.
pub fn format_delta_message(
  sequence_number: Int,
  client_sequence_number: Int,
  minimum_sequence_number: Int,
  client_id: JsonTerm,
  reference_sequence_number: Int,
  msg_type: String,
  contents: JsonTerm,
  metadata: JsonTerm,
  timestamp: Int,
  data: JsonTerm,
) -> List(#(String, JsonTerm)) {
  let base = [
    #("sequenceNumber", term_int(sequence_number)),
    #("clientSequenceNumber", term_int(client_sequence_number)),
    #("minimumSequenceNumber", term_int(minimum_sequence_number)),
    #("clientId", client_id),
    #("referenceSequenceNumber", term_int(reference_sequence_number)),
    #("type", term_string(msg_type)),
    #("contents", contents),
    #("metadata", metadata),
    #("timestamp", term_int(timestamp)),
  ]

  case requires_data_field(msg_type) {
    True -> list.append(base, [#("data", data)])
    False -> base
  }
}
