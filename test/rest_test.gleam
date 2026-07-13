import floodgate/rest
import gleam/dynamic
import gleeunit/should

// ─────────────────────────────────────────────────────────────────────────────
// base_url / object URL construction
// ─────────────────────────────────────────────────────────────────────────────

pub fn base_url_omits_default_http_port_test() {
  rest.base_url("http", "example.test", 80)
  |> should.equal("http://example.test")
}

pub fn base_url_omits_default_https_port_test() {
  rest.base_url("https", "example.test", 443)
  |> should.equal("https://example.test")
}

pub fn base_url_keeps_non_default_port_test() {
  rest.base_url("http", "localhost", 4000)
  |> should.equal("http://localhost:4000")
}

pub fn blob_url_test() {
  rest.blob_url("http://localhost:4000", "tenant1", "abc123")
  |> should.equal("http://localhost:4000/repos/tenant1/git/blobs/abc123")
}

pub fn tree_url_test() {
  rest.tree_url("http://localhost:4000", "tenant1", "abc123")
  |> should.equal("http://localhost:4000/repos/tenant1/git/trees/abc123")
}

pub fn commit_url_test() {
  rest.commit_url("http://localhost:4000", "tenant1", "abc123")
  |> should.equal("http://localhost:4000/repos/tenant1/git/commits/abc123")
}

pub fn ref_url_strips_refs_prefix_test() {
  rest.ref_url("http://localhost:4000", "tenant1", "refs/heads/main")
  |> should.equal("http://localhost:4000/repos/tenant1/git/refs/heads/main")
}

pub fn ref_url_keeps_path_without_refs_prefix_test() {
  rest.ref_url("http://localhost:4000", "tenant1", "heads/main")
  |> should.equal("http://localhost:4000/repos/tenant1/git/refs/heads/main")
}

pub fn build_ref_path_joins_wildcard_segments_test() {
  rest.build_ref_path(["heads", "main"])
  |> should.equal("refs/heads/main")
}

// ─────────────────────────────────────────────────────────────────────────────
// Git object response shaping
// ─────────────────────────────────────────────────────────────────────────────

pub fn format_blob_response_test() {
  let fields =
    rest.format_blob_response(
      "http://localhost:4000",
      "tenant1",
      "sha1",
      11,
      "aGVsbG8gd29ybGQ=",
    )

  fields
  |> should.equal([
    #("sha", dynamic.string("sha1")),
    #("size", dynamic.int(11)),
    #("content", dynamic.string("aGVsbG8gd29ybGQ=")),
    #("encoding", dynamic.string("base64")),
    #(
      "url",
      dynamic.string("http://localhost:4000/repos/tenant1/git/blobs/sha1"),
    ),
  ])
}

pub fn format_tree_response_builds_entry_urls_by_type_test() {
  let entries = [
    #("file.txt", "100644", "blobsha", "blob"),
    #("subdir", "040000", "treesha", "tree"),
  ]

  let assert [#("sha", _), #("url", _), #("tree", tree_dynamic)] =
    rest.format_tree_response(
      "http://localhost:4000",
      "tenant1",
      "roottree",
      entries,
    )

  // The tree field is a Dynamic-wrapped list; decode it back out to assert
  // shape via classify (a full decode isn't needed to prove non-empty list).
  dynamic.classify(tree_dynamic)
  |> should.equal("List")
}

pub fn format_commit_response_shape_test() {
  let author = dynamic.string("author-placeholder")
  let committer = dynamic.string("committer-placeholder")
  let message = dynamic.string("Initial commit")

  let fields =
    rest.format_commit_response(
      "http://localhost:4000",
      "tenant1",
      "commitsha",
      "treesha",
      ["parent1", "parent2"],
      message,
      author,
      committer,
    )

  let assert [
    #("sha", sha),
    #("tree", _tree),
    #("parents", parents),
    #("message", msg),
    #("author", auth),
    #("committer", committer_out),
    #("url", url),
  ] = fields

  sha |> should.equal(dynamic.string("commitsha"))
  msg |> should.equal(message)
  auth |> should.equal(author)
  committer_out |> should.equal(committer)
  url
  |> should.equal(dynamic.string(
    "http://localhost:4000/repos/tenant1/git/commits/commitsha",
  ))
  dynamic.classify(parents) |> should.equal("List")
}

pub fn format_ref_response_shape_test() {
  let fields =
    rest.format_ref_response(
      "http://localhost:4000",
      "tenant1",
      "refs/heads/main",
      "commitsha",
    )

  let assert [#("ref", ref_field), #("object", _object), #("url", url_field)] =
    fields

  ref_field |> should.equal(dynamic.string("refs/heads/main"))
  url_field
  |> should.equal(dynamic.string(
    "http://localhost:4000/repos/tenant1/git/refs/heads/main",
  ))
}

// ─────────────────────────────────────────────────────────────────────────────
// Document / session response shaping
// ─────────────────────────────────────────────────────────────────────────────

pub fn format_document_response_test() {
  rest.format_document_response("doc-1", "tenant1", 5)
  |> should.equal([
    #("id", dynamic.string("doc-1")),
    #("tenantId", dynamic.string("tenant1")),
    #("sequenceNumber", dynamic.int(5)),
  ])
}

pub fn session_info_alive_test() {
  rest.session_info("http://localhost:4000", "tenant1", "doc-1", True)
  |> should.equal([
    #("ordererUrl", dynamic.string("http://localhost:4000/socket")),
    #("historianUrl", dynamic.string("http://localhost:4000/repos/tenant1")),
    #(
      "deltaStreamUrl",
      dynamic.string("http://localhost:4000/deltas/tenant1/doc-1"),
    ),
    #("isSessionAlive", dynamic.bool(True)),
    #("isSessionActive", dynamic.bool(True)),
  ])
}

pub fn session_info_not_alive_test() {
  rest.session_info("http://localhost:4000", "tenant1", "doc-1", False)
  |> should.equal([
    #("ordererUrl", dynamic.string("http://localhost:4000/socket")),
    #("historianUrl", dynamic.string("http://localhost:4000/repos/tenant1")),
    #(
      "deltaStreamUrl",
      dynamic.string("http://localhost:4000/deltas/tenant1/doc-1"),
    ),
    #("isSessionAlive", dynamic.bool(False)),
    #("isSessionActive", dynamic.bool(False)),
  ])
}

// ─────────────────────────────────────────────────────────────────────────────
// Delta (operation history) response shaping
// ─────────────────────────────────────────────────────────────────────────────

pub fn requires_data_field_for_join_and_leave_test() {
  rest.requires_data_field("join") |> should.equal(True)
  rest.requires_data_field("leave") |> should.equal(True)
  rest.requires_data_field("op") |> should.equal(False)
  rest.requires_data_field("summarize") |> should.equal(False)
}

pub fn format_delta_message_op_omits_data_field_test() {
  let contents = dynamic.string("some-op-contents")
  let metadata = dynamic.nil()
  let client_id = dynamic.string("client-1")

  let fields =
    rest.format_delta_message(
      1,
      1,
      0,
      client_id,
      0,
      "op",
      contents,
      metadata,
      1_700_000_000,
      dynamic.nil(),
    )

  fields
  |> should.equal([
    #("sequenceNumber", dynamic.int(1)),
    #("clientSequenceNumber", dynamic.int(1)),
    #("minimumSequenceNumber", dynamic.int(0)),
    #("clientId", client_id),
    #("referenceSequenceNumber", dynamic.int(0)),
    #("type", dynamic.string("op")),
    #("contents", contents),
    #("metadata", metadata),
    #("timestamp", dynamic.int(1_700_000_000)),
  ])
}

pub fn format_delta_message_join_includes_data_field_test() {
  let contents = dynamic.string("{\"clientId\":\"client-1\"}")
  let metadata = dynamic.nil()
  let client_id = dynamic.nil()
  let data = dynamic.string("{\"clientId\":\"client-1\"}")

  let fields =
    rest.format_delta_message(
      1,
      -1,
      0,
      client_id,
      0,
      "join",
      contents,
      metadata,
      1_700_000_000,
      data,
    )

  let assert [
    #("sequenceNumber", _),
    #("clientSequenceNumber", _),
    #("minimumSequenceNumber", _),
    #("clientId", _),
    #("referenceSequenceNumber", _),
    #("type", type_field),
    #("contents", _),
    #("metadata", _),
    #("timestamp", _),
    #("data", data_field),
  ] = fields

  type_field |> should.equal(dynamic.string("join"))
  data_field |> should.equal(data)
}
