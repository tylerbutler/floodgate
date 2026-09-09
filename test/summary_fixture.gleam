import floodgate/document_channel
import floodgate/git
import floodgate/store
import gleam/dict
import gleam/dynamic/decode
import gleam/json
import gleam/list
import spillway/session_logic

pub fn tree(backend: store.Backend, topic: String, content: String) -> String {
  let blob =
    json.object([
      #("content", json.string(content)),
      #("encoding", json.string("utf-8")),
    ])
    |> json.to_string
  let assert Ok(blob_sha) = git.create(backend, topic, "blobs", blob)
  let body =
    json.object([
      #(
        "tree",
        json.preprocessed_array([
          json.object([
            #("path", json.string("file.txt")),
            #("mode", json.string("100644")),
            #("type", json.string("blob")),
            #("sha", json.string(blob_sha)),
          ]),
        ]),
      ),
    ])
    |> json.to_string
  let assert Ok(sha) = git.create(backend, topic, "trees", body)
  sha
}

pub fn commit(
  backend: store.Backend,
  topic: String,
  tree_sha: String,
  parents: List(String),
  message: String,
) -> String {
  let author =
    json.object([
      #("name", json.string("Summary fixture")),
      #("email", json.string("fixture@floodgate.local")),
      #("date", json.string("0")),
    ])
  let body =
    json.object([
      #("tree", json.string(tree_sha)),
      #("parents", json.array(parents, json.string)),
      #("message", json.string(message)),
      #("author", author),
      #("committer", author),
    ])
    |> json.to_string
  let assert Ok(sha) = git.create(backend, topic, "commits", body)
  sha
}

pub fn contents(tree_sha: String, head: String) -> json.Json {
  json.object([
    #("handle", json.string(tree_sha)),
    #("head", json.string(head)),
    #(
      "parents",
      json.array(
        case head {
          "" -> []
          _ -> [head]
        },
        json.string,
      ),
    ),
    #("message", json.string("Summary fixture")),
  ])
}

pub fn proposal(
  proposal_sn: Int,
  reference_sn: Int,
  tree_sha: String,
  head: String,
) -> String {
  json.object([
    #("clientId", json.string("summary-client")),
    #("clientSequenceNumber", json.int(1)),
    #("sequenceNumber", json.int(proposal_sn)),
    #("referenceSequenceNumber", json.int(reference_sn)),
    #("minimumSequenceNumber", json.int(0)),
    #("type", json.string("summarize")),
    #("contents", contents(tree_sha, head)),
    #("timestamp", json.int(0)),
  ])
  |> json.to_string
}

pub fn ack(proposal_sn: Int, commit_sha: String) -> String {
  session_logic.build_summary_ack(commit_sha, proposal_sn, 0, 0)
  |> list.map(fn(field) {
    #(field.0, document_channel.dynamic_to_json(field.1))
  })
  |> json.object
  |> json.to_string
}

pub fn stringify_contents(message: String) -> String {
  let assert Ok(fields) =
    json.parse(message, decode.dict(decode.string, decode.dynamic))
  fields
  |> dict.to_list
  |> list.map(fn(field) {
    let value = document_channel.dynamic_to_json(field.1)
    #(field.0, case field.0 {
      "contents" -> json.string(json.to_string(value))
      _ -> value
    })
  })
  |> json.object
  |> json.to_string
}
