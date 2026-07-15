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
