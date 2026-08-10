//// Persists Routerlicious' document-create whole-summary payload into the
//// shredded Historian object graph used by the official driver on load.

import floodgate/git
import floodgate/store
import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

type SummaryValue {
  SummaryTree(entries: List(SummaryEntry))
  SummaryBlob(content: String, encoding: String)
}

type SummaryEntry {
  SummaryEntry(
    path: String,
    kind: String,
    value: Option(SummaryValue),
    id: Option(String),
  )
}

type CreatePayload {
  CreatePayload(
    summary: Option(SummaryValue),
    sequence_number: Int,
    values: Dynamic,
  )
}

@external(erlang, "floodgate_ffi", "json_encode")
fn json_encode(value: Dynamic) -> String

/// Store the Historian objects for a create payload's initial summary and return
/// the commit sha with its sequence number, or `None` when the payload carries no
/// summary.
///
/// Objects only. `refs/heads/<document_id>` is published by the caller once the
/// session has committed the summary pointer, so a crash can only leave the ref
/// lagging, never leading. See `git.publish_summary_ref`.
///
/// Scoped by `topic` rather than tenant because objects belong to a document —
/// see `git.create`. Nothing in here needs the tenant on its own.
pub fn persist(
  storage: store.Backend,
  topic: String,
  body: String,
  timestamp: Int,
) -> Result(Option(#(String, Int)), Nil) {
  case string.trim(body) {
    "" -> Ok(None)
    _ -> {
      use payload <- result.try(
        json.parse(body, create_payload_decoder()) |> result.replace_error(Nil),
      )
      case payload.summary {
        None -> Ok(None)
        Some(SummaryBlob(_, _)) -> Error(Nil)
        Some(SummaryTree(entries)) -> {
          use tree_sha <- result.try(persist_root_tree(
            storage,
            topic,
            entries,
            payload,
          ))
          let author =
            json.object([
              #("name", json.string("Floodgate")),
              #("email", json.string("server@floodgate.local")),
              #("date", json.string(int.to_string(timestamp))),
            ])
          let commit =
            json.object([
              #("tree", json.string(tree_sha)),
              #("parents", json.array([], json.string)),
              #("message", json.string("Initial summary")),
              #("author", author),
              #("committer", author),
            ])
            |> json.to_string
          use commit_sha <- result.try(git.create(
            storage,
            topic,
            "commits",
            commit,
          ))
          Ok(Some(#(commit_sha, payload.sequence_number)))
        }
      }
    }
  }
}

/// The two client stacks post structurally different create payloads, and the
/// resulting Historian graph has to be the one each stack's loader can read:
///
///   - The official Routerlicious driver splits the combined summary itself and
///     posts the `.app` contents as `summary` plus the quorum in `values`. The
///     protocol tree is synthesized here, and the root is `.app` + `.protocol`.
///   - `levee-driver` posts the whole combined `ISummaryTree`, `.app` and
///     `.protocol` included, and no `values`. Its `convertGitTreeToSnapshotTree`
///     does not unwrap `.app`, so — exactly as levee's
///     `process_initial_summary/3` does — `.app`'s *children* are flattened to
///     the root tree and the summary's own `.protocol` is stored beside them.
fn persist_root_tree(
  storage: store.Backend,
  topic: String,
  entries: List(SummaryEntry),
  payload: CreatePayload,
) -> Result(String, Nil) {
  case find_entry(entries, ".app") {
    Some(SummaryTree(app_entries)) -> {
      use app_tree_entries <- result.try(
        list.try_map(app_entries, persist_entry(storage, topic, _)),
      )
      use protocol_entries <- result.try(case find_entry(entries, ".protocol") {
        Some(SummaryTree(_) as protocol) -> {
          use sha <- result.try(persist_value(storage, topic, protocol))
          Ok([subtree_entry(".protocol", sha)])
        }
        _ -> Ok([])
      })
      persist_tree_entries(
        storage,
        topic,
        list.append(app_tree_entries, protocol_entries),
      )
    }
    _ -> {
      use app_tree_sha <- result.try(persist_tree(storage, topic, entries))
      use protocol_tree_sha <- result.try(persist_protocol(
        storage,
        topic,
        payload.sequence_number,
        payload.values,
      ))
      persist_tree_entries(storage, topic, [
        subtree_entry(".app", app_tree_sha),
        subtree_entry(".protocol", protocol_tree_sha),
      ])
    }
  }
}

fn find_entry(
  entries: List(SummaryEntry),
  path: String,
) -> Option(SummaryValue) {
  case list.find(entries, fn(entry) { entry.path == path }) {
    Ok(entry) -> entry.value
    Error(_) -> None
  }
}

fn persist_tree(
  storage: store.Backend,
  topic: String,
  entries: List(SummaryEntry),
) -> Result(String, Nil) {
  use stored_entries <- result.try(
    list.try_map(entries, persist_entry(storage, topic, _)),
  )
  persist_tree_entries(storage, topic, stored_entries)
}

fn persist_protocol(
  storage: store.Backend,
  topic: String,
  sequence_number: Int,
  values: Dynamic,
) -> Result(String, Nil) {
  let attributes =
    json.object([
      #("minimumSequenceNumber", json.int(sequence_number)),
      #("sequenceNumber", json.int(sequence_number)),
    ])
    |> json.to_string
  use attributes_sha <- result.try(persist_value(
    storage,
    topic,
    SummaryBlob(attributes, "utf-8"),
  ))
  use quorum_values_sha <- result.try(persist_value(
    storage,
    topic,
    SummaryBlob(json_encode(values), "utf-8"),
  ))
  use quorum_members_sha <- result.try(persist_value(
    storage,
    topic,
    SummaryBlob("[]", "utf-8"),
  ))
  use quorum_proposals_sha <- result.try(persist_value(
    storage,
    topic,
    SummaryBlob("[]", "utf-8"),
  ))
  persist_tree_entries(storage, topic, [
    blob_tree_entry("attributes", attributes_sha),
    blob_tree_entry("quorumMembers", quorum_members_sha),
    blob_tree_entry("quorumProposals", quorum_proposals_sha),
    blob_tree_entry("quorumValues", quorum_values_sha),
  ])
}

fn persist_tree_entries(
  storage: store.Backend,
  topic: String,
  stored_entries: List(json.Json),
) -> Result(String, Nil) {
  json.object([#("tree", json.preprocessed_array(stored_entries))])
  |> json.to_string
  |> git.create(storage, topic, "trees", _)
}

fn blob_tree_entry(path: String, sha: String) -> json.Json {
  tree_entry(path, "blob", "100644", sha)
}

fn subtree_entry(path: String, sha: String) -> json.Json {
  tree_entry(path, "tree", "040000", sha)
}

fn tree_entry(
  path: String,
  kind: String,
  mode: String,
  sha: String,
) -> json.Json {
  json.object([
    #("path", json.string(path)),
    #("mode", json.string(mode)),
    #("type", json.string(kind)),
    #("sha", json.string(sha)),
  ])
}

fn persist_entry(
  storage: store.Backend,
  topic: String,
  entry: SummaryEntry,
) -> Result(json.Json, Nil) {
  use sha <- result.try(case entry.value, entry.id {
    Some(value), None -> persist_value(storage, topic, value)
    None, Some(id) -> {
      use _ <- result.try(git.fetch(storage, topic, id))
      Ok(id)
    }
    _, _ -> Error(Nil)
  })
  use mode <- result.try(mode(entry.kind))
  Ok(
    json.object([
      #("path", json.string(entry.path)),
      #("mode", json.string(mode)),
      #("type", json.string(entry.kind)),
      #("sha", json.string(sha)),
    ]),
  )
}

fn persist_value(
  storage: store.Backend,
  topic: String,
  value: SummaryValue,
) -> Result(String, Nil) {
  case value {
    SummaryTree(entries) -> persist_tree(storage, topic, entries)
    SummaryBlob(content, encoding) ->
      json.object([
        #("content", json.string(content)),
        #("encoding", json.string(encoding)),
      ])
      |> json.to_string
      |> git.create(storage, topic, "blobs", _)
  }
}

fn mode(kind: String) -> Result(String, Nil) {
  case kind {
    "blob" -> Ok("100644")
    "tree" -> Ok("040000")
    "commit" -> Ok("160000")
    _ -> Error(Nil)
  }
}

fn create_payload_decoder() -> decode.Decoder(CreatePayload) {
  use summary <- decode.optional_field(
    "summary",
    None,
    decode.optional(summary_value_decoder()),
  )
  use sequence_number <- decode.optional_field("sequenceNumber", 0, decode.int)
  use values <- decode.optional_field(
    "values",
    dynamic.list([]),
    decode.dynamic,
  )
  decode.success(CreatePayload(summary, sequence_number, values))
}

/// Two wire shapes reach this endpoint and both have to work, because one
/// floodgate process serves both client stacks (ADR-008):
///
///   - Routerlicious whole-summary — string `type`, `entries` array — sent by
///     the official driver via `floodgate-client`.
///   - Fluid `ISummaryTree` — numeric `type`, `tree` map keyed by path — sent
///     by `levee-driver`/`levee-client`, and the only shape levee's
///     `process_initial_summary/3` accepts.
fn summary_value_decoder() -> decode.Decoder(SummaryValue) {
  use <- decode.recursive
  decode.one_of(routerlicious_summary_value_decoder(), [
    fluid_summary_value_decoder(),
  ])
}

fn routerlicious_summary_value_decoder() -> decode.Decoder(SummaryValue) {
  use kind <- decode.field("type", decode.string)
  case kind {
    "tree" -> {
      use entries <- decode.optional_field(
        "entries",
        [],
        decode.list(summary_entry_decoder()),
      )
      decode.success(SummaryTree(entries))
    }
    "blob" -> {
      use content <- decode.field("content", decode.string)
      use encoding <- decode.optional_field("encoding", "utf-8", decode.string)
      decode.success(SummaryBlob(content, encoding))
    }
    _ -> decode.failure(SummaryTree([]), "whole summary value")
  }
}

/// `SummaryType.Tree` = 1 and `SummaryType.Blob` = 2 in
/// `@fluidframework/driver-definitions`. Handles (3) and attachments (4) only
/// appear in incremental summaries, never in a create-container payload.
fn fluid_summary_value_decoder() -> decode.Decoder(SummaryValue) {
  use kind <- decode.field("type", decode.int)
  case kind {
    1 -> {
      use tree <- decode.optional_field(
        "tree",
        dict.new(),
        decode.dict(decode.string, summary_value_decoder()),
      )
      decode.success(SummaryTree(fluid_tree_entries(tree)))
    }
    2 -> {
      use content <- decode.field("content", blob_content_decoder())
      decode.success(SummaryBlob(content, "utf-8"))
    }
    _ -> decode.failure(SummaryTree([]), "fluid summary value")
  }
}

/// The path→node map carries no explicit entry kind; it follows from the node.
/// Sorted so the resulting tree object is deterministic for a given summary.
fn fluid_tree_entries(
  tree: dict.Dict(String, SummaryValue),
) -> List(SummaryEntry) {
  tree
  |> dict.to_list
  |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
  |> list.map(fn(pair) {
    let #(path, value) = pair
    let kind = case value {
      SummaryTree(_) -> "tree"
      SummaryBlob(_, _) -> "blob"
    }
    SummaryEntry(path, kind, Some(value), None)
  })
}

/// `ISummaryBlob.content` is `string | Uint8Array` in the Fluid types, and
/// callers put plain JSON there too. Levee re-encodes anything non-binary with
/// `Jason.encode!/1`; do the same rather than rejecting the summary.
fn blob_content_decoder() -> decode.Decoder(String) {
  decode.one_of(decode.string, [decode.map(decode.dynamic, json_encode)])
}

fn summary_entry_decoder() -> decode.Decoder(SummaryEntry) {
  use path <- decode.field("path", decode.string)
  use kind <- decode.field("type", decode.string)
  use value <- decode.optional_field(
    "value",
    None,
    decode.optional(summary_value_decoder()),
  )
  use id <- decode.optional_field("id", None, decode.optional(decode.string))
  decode.success(SummaryEntry(path, kind, value, id))
}
