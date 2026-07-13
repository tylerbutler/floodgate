//// Persists Routerlicious' document-create whole-summary payload into the
//// shredded Historian object graph used by the official driver on load.

import floodgate/git
import floodgate/store
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

pub fn persist(
  storage: store.Backend,
  tenant: String,
  document_id: String,
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
          use app_tree_sha <- result.try(persist_tree(storage, tenant, entries))
          use protocol_tree_sha <- result.try(persist_protocol(
            storage,
            tenant,
            payload.sequence_number,
            payload.values,
          ))
          use tree_sha <- result.try(
            persist_tree_entries(storage, tenant, [
              tree_entry(".app", "tree", app_tree_sha),
              tree_entry(".protocol", "tree", protocol_tree_sha),
            ]),
          )
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
            tenant,
            "commits",
            commit,
          ))
          git.put_ref(storage, tenant, "refs/heads/" <> document_id, commit_sha)
          Ok(Some(#(commit_sha, payload.sequence_number)))
        }
      }
    }
  }
}

fn persist_tree(
  storage: store.Backend,
  tenant: String,
  entries: List(SummaryEntry),
) -> Result(String, Nil) {
  use stored_entries <- result.try(
    list.try_map(entries, persist_entry(storage, tenant, _)),
  )
  persist_tree_entries(storage, tenant, stored_entries)
}

fn persist_protocol(
  storage: store.Backend,
  tenant: String,
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
    tenant,
    SummaryBlob(attributes, "utf-8"),
  ))
  use quorum_values_sha <- result.try(persist_value(
    storage,
    tenant,
    SummaryBlob(json_encode(values), "utf-8"),
  ))
  use quorum_members_sha <- result.try(persist_value(
    storage,
    tenant,
    SummaryBlob("[]", "utf-8"),
  ))
  use quorum_proposals_sha <- result.try(persist_value(
    storage,
    tenant,
    SummaryBlob("[]", "utf-8"),
  ))
  persist_tree_entries(storage, tenant, [
    tree_entry("attributes", "blob", attributes_sha),
    tree_entry("quorumMembers", "blob", quorum_members_sha),
    tree_entry("quorumProposals", "blob", quorum_proposals_sha),
    tree_entry("quorumValues", "blob", quorum_values_sha),
  ])
}

fn persist_tree_entries(
  storage: store.Backend,
  tenant: String,
  stored_entries: List(json.Json),
) -> Result(String, Nil) {
  json.object([#("tree", json.preprocessed_array(stored_entries))])
  |> json.to_string
  |> git.create(storage, tenant, "trees", _)
}

fn tree_entry(path: String, kind: String, sha: String) -> json.Json {
  let assert Ok(mode) = mode(kind)
  json.object([
    #("path", json.string(path)),
    #("mode", json.string(mode)),
    #("type", json.string(kind)),
    #("sha", json.string(sha)),
  ])
}

fn persist_entry(
  storage: store.Backend,
  tenant: String,
  entry: SummaryEntry,
) -> Result(json.Json, Nil) {
  use sha <- result.try(case entry.value, entry.id {
    Some(value), None -> persist_value(storage, tenant, value)
    None, Some(id) -> {
      use _ <- result.try(git.fetch(storage, tenant, id))
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
  tenant: String,
  value: SummaryValue,
) -> Result(String, Nil) {
  case value {
    SummaryTree(entries) -> persist_tree(storage, tenant, entries)
    SummaryBlob(content, encoding) ->
      json.object([
        #("content", json.string(content)),
        #("encoding", json.string(encoding)),
      ])
      |> json.to_string
      |> git.create(storage, tenant, "blobs", _)
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

fn create_payload_decoder() {
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

fn summary_value_decoder() -> decode.Decoder(SummaryValue) {
  use <- decode.recursive
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

fn summary_entry_decoder() {
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
