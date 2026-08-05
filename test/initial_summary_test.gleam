import floodgate/git
import floodgate/initial_summary
import floodgate/memory_store
import floodgate/store
import gleam/json
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should

pub fn persists_whole_summary_as_historian_graph_test() {
  let storage = memory_store.new()
  store.open(storage)
  let tenant = "initial-summary-tenant"
  let document_id = "initial-summary-doc"
  let body =
    json.object([
      #(
        "summary",
        json.object([
          #("type", json.string("tree")),
          #(
            "entries",
            json.preprocessed_array([
              json.object([
                #("path", json.string("root")),
                #("type", json.string("tree")),
                #(
                  "value",
                  json.object([
                    #("type", json.string("tree")),
                    #(
                      "entries",
                      json.preprocessed_array([
                        json.object([
                          #("path", json.string("value")),
                          #("type", json.string("blob")),
                          #(
                            "value",
                            json.object([
                              #("type", json.string("blob")),
                              #("content", json.string("hello")),
                              #("encoding", json.string("utf-8")),
                            ]),
                          ),
                        ]),
                      ]),
                    ),
                  ]),
                ),
              ]),
            ]),
          ),
        ]),
      ),
      #("sequenceNumber", json.int(7)),
    ])
    |> json.to_string

  let assert Ok(Some(#(commit_sha, 7))) =
    initial_summary.persist(storage, tenant, document_id, body, 1_700_000_000)
  git.get_ref(storage, tenant, "refs/heads/" <> document_id)
  |> should.equal(Ok(commit_sha))

  let assert Ok(commit_body) = git.fetch(storage, tenant, commit_sha)
  let assert Ok(commit_response) =
    git.commit_details_response(
      "http://localhost",
      tenant,
      commit_sha,
      commit_body,
    )
  commit_response
  |> json.to_string
  |> string.contains("\"message\":\"Initial summary\"")
  |> should.be_true
}

/// `levee-driver` posts the raw Fluid `ISummaryTree` — numeric `type` and a
/// `tree` map keyed by path — rather than the Routerlicious whole-summary
/// `entries` array. Levee's `process_initial_summary/3` matches on
/// `%{"type" => 1, "tree" => tree}`, so floodgate has to persist that shape too
/// or `levee-client` containers cannot be created.
pub fn persists_fluid_summary_tree_shape_test() {
  let storage = memory_store.new()
  store.open(storage)
  let tenant = "fluid-shape-tenant"
  let document_id = "fluid-shape-doc"

  let blob_node = fn(content: String) {
    json.object([#("type", json.int(2)), #("content", json.string(content))])
  }
  let body =
    json.object([
      #(
        "summary",
        json.object([
          #("type", json.int(1)),
          #(
            "tree",
            json.object([
              #(
                ".app",
                json.object([
                  #("type", json.int(1)),
                  #("tree", json.object([#("value", blob_node("hello"))])),
                ]),
              ),
              #(
                ".protocol",
                json.object([
                  #("type", json.int(1)),
                  #(
                    "tree",
                    json.object([
                      #("attributes", blob_node("{\"sequenceNumber\":0}")),
                    ]),
                  ),
                ]),
              ),
            ]),
          ),
        ]),
      ),
      #("sequenceNumber", json.int(3)),
    ])
    |> json.to_string

  let assert Ok(Some(#(commit_sha, 3))) =
    initial_summary.persist(storage, tenant, document_id, body, 1_700_000_000)
  git.get_ref(storage, tenant, "refs/heads/" <> document_id)
  |> should.equal(Ok(commit_sha))
}

/// A blob's `content` is `unknown` in the Fluid types; levee re-encodes a
/// non-string with `Jason.encode!/1` rather than rejecting it.
pub fn accepts_non_string_fluid_blob_content_test() {
  let storage = memory_store.new()
  store.open(storage)
  let body =
    json.object([
      #(
        "summary",
        json.object([
          #("type", json.int(1)),
          #(
            "tree",
            json.object([
              #(
                ".app",
                json.object([
                  #("type", json.int(1)),
                  #(
                    "tree",
                    json.object([
                      #(
                        "structured",
                        json.object([
                          #("type", json.int(2)),
                          #("content", json.object([#("nested", json.int(1))])),
                        ]),
                      ),
                    ]),
                  ),
                ]),
              ),
            ]),
          ),
        ]),
      ),
    ])
    |> json.to_string

  let assert Ok(Some(_)) =
    initial_summary.persist(storage, "json-content", "doc", body, 0)
}

pub fn accepts_document_create_without_summary_test() {
  initial_summary.persist(memory_store.new(), "no-summary", "doc", "{}", 0)
  |> should.equal(Ok(None))
}

pub fn rejects_blob_as_summary_root_test() {
  let body =
    "{\"summary\":{\"type\":\"blob\",\"content\":\"invalid\",\"encoding\":\"utf-8\"}}"
  initial_summary.persist(memory_store.new(), "invalid-summary", "doc", body, 0)
  |> should.equal(Error(Nil))
}
