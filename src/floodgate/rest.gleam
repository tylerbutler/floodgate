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
pub fn ref_url(base_url: String, tenant_id: String, ref_path: String) -> String {
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
) -> List(#(String, Dynamic)) {
  [
    #("sha", dynamic.string(sha)),
    #("size", dynamic.int(size)),
    #("content", dynamic.string(content_base64)),
    #("encoding", dynamic.string("base64")),
    #("url", dynamic.string(blob_url(base_url, tenant_id, sha))),
  ]
}

/// One entry of a tree's `tree` array: `#(path, mode, sha, type)`.
pub type TreeEntryIn =
  #(String, String, String, String)

fn format_tree_entry(
  base_url: String,
  tenant_id: String,
  entry: TreeEntryIn,
) -> Dynamic {
  let #(path, mode, sha, entry_type) = entry

  let entry_url = case entry_type {
    "blob" -> dynamic.string(blob_url(base_url, tenant_id, sha))
    "tree" -> dynamic.string(tree_url(base_url, tenant_id, sha))
    _ -> dynamic.nil()
  }

  dynamic.properties([
    #(dynamic.string("path"), dynamic.string(path)),
    #(dynamic.string("mode"), dynamic.string(mode)),
    #(dynamic.string("sha"), dynamic.string(sha)),
    #(dynamic.string("type"), dynamic.string(entry_type)),
    #(dynamic.string("url"), entry_url),
  ])
}

pub fn format_tree_response(
  base_url: String,
  tenant_id: String,
  sha: String,
  entries: List(TreeEntryIn),
) -> List(#(String, Dynamic)) {
  let formatted_entries =
    list.map(entries, format_tree_entry(base_url, tenant_id, _))

  [
    #("sha", dynamic.string(sha)),
    #("url", dynamic.string(tree_url(base_url, tenant_id, sha))),
    #("tree", dynamic.list(formatted_entries)),
  ]
}

pub fn format_commit_response(
  base_url: String,
  tenant_id: String,
  sha: String,
  tree_sha: String,
  parents: List(String),
  message: Dynamic,
  author: Dynamic,
  committer: Dynamic,
) -> List(#(String, Dynamic)) {
  let tree_obj =
    dynamic.properties([
      #(dynamic.string("sha"), dynamic.string(tree_sha)),
      #(
        dynamic.string("url"),
        dynamic.string(tree_url(base_url, tenant_id, tree_sha)),
      ),
    ])

  let formatted_parents =
    list.map(parents, fn(parent_sha) {
      dynamic.properties([
        #(dynamic.string("sha"), dynamic.string(parent_sha)),
        #(
          dynamic.string("url"),
          dynamic.string(commit_url(base_url, tenant_id, parent_sha)),
        ),
      ])
    })

  [
    #("sha", dynamic.string(sha)),
    #("tree", tree_obj),
    #("parents", dynamic.list(formatted_parents)),
    #("message", message),
    #("author", author),
    #("committer", committer),
    #("url", dynamic.string(commit_url(base_url, tenant_id, sha))),
  ]
}

pub fn format_ref_response(
  base_url: String,
  tenant_id: String,
  ref_path: String,
  sha: String,
) -> List(#(String, Dynamic)) {
  let object =
    dynamic.properties([
      #(dynamic.string("sha"), dynamic.string(sha)),
      #(dynamic.string("type"), dynamic.string("commit")),
      #(
        dynamic.string("url"),
        dynamic.string(commit_url(base_url, tenant_id, sha)),
      ),
    ])

  [
    #("ref", dynamic.string(ref_path)),
    #("object", object),
    #("url", dynamic.string(ref_url(base_url, tenant_id, ref_path))),
  ]
}

// ─────────────────────────────────────────────────────────────────────────────
// Document / session response shaping
// ─────────────────────────────────────────────────────────────────────────────

pub fn format_document_response(
  id: String,
  tenant_id: String,
  sequence_number: Int,
) -> List(#(String, Dynamic)) {
  [
    #("id", dynamic.string(id)),
    #("tenantId", dynamic.string(tenant_id)),
    #("sequenceNumber", dynamic.int(sequence_number)),
  ]
}

/// Build the `GET /documents/:tenant/session/:id` response shape.
pub fn session_info(
  host: String,
  tenant_id: String,
  document_id: String,
  is_alive: Bool,
) -> List(#(String, Dynamic)) {
  [
    #("ordererUrl", dynamic.string(host <> "/socket")),
    #("historianUrl", dynamic.string(host <> "/repos/" <> tenant_id)),
    #(
      "deltaStreamUrl",
      dynamic.string(host <> "/deltas/" <> tenant_id <> "/" <> document_id),
    ),
    #("isSessionAlive", dynamic.bool(is_alive)),
    #("isSessionActive", dynamic.bool(is_alive)),
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
  client_id: Dynamic,
  reference_sequence_number: Int,
  msg_type: String,
  contents: Dynamic,
  metadata: Dynamic,
  timestamp: Int,
  data: Dynamic,
) -> List(#(String, Dynamic)) {
  let base = [
    #("sequenceNumber", dynamic.int(sequence_number)),
    #("clientSequenceNumber", dynamic.int(client_sequence_number)),
    #("minimumSequenceNumber", dynamic.int(minimum_sequence_number)),
    #("clientId", client_id),
    #("referenceSequenceNumber", dynamic.int(reference_sequence_number)),
    #("type", dynamic.string(msg_type)),
    #("contents", contents),
    #("metadata", metadata),
    #("timestamp", dynamic.int(timestamp)),
  ]

  case requires_data_field(msg_type) {
    True -> list.append(base, [#("data", data)])
    False -> base
  }
}
