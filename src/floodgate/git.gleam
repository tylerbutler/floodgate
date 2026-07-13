//// Content-addressed Historian storage for blobs, trees, commits, and refs.

import floodgate/store
import gleam/bit_array
import gleam/crypto
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/result
import gleam/string

type Person {
  Person(name: String, email: String, date: String)
}

type TreeEntry {
  TreeEntry(path: String, mode: String, kind: String, size: Int, sha: String)
}

type Commit {
  Commit(
    tree: String,
    parents: List(String),
    message: String,
    author: Person,
    committer: Person,
  )
}

/// Store an object's raw body, returning its content-addressed id.
pub fn create(
  storage: store.Backend,
  tenant: String,
  kind: String,
  body: String,
) -> Result(String, Nil) {
  use sha <- result.try(case kind {
    "blobs" -> blob_sha(body)
    "trees" | "commits" -> Ok(sha1(bit_array.from_string(body)))
    _ -> Error(Nil)
  })
  store.put_obj(storage, tenant, sha, body)
  Ok(sha)
}

/// Fetch an object's raw body by SHA.
pub fn fetch(
  storage: store.Backend,
  tenant: String,
  sha: String,
) -> Result(String, Nil) {
  store.get_obj(storage, tenant, sha)
}

pub fn put_ref(
  storage: store.Backend,
  tenant: String,
  ref: String,
  sha: String,
) -> Nil {
  store.put_ref(storage, tenant, normalize_ref(ref), sha)
}

pub fn create_ref(
  storage: store.Backend,
  tenant: String,
  ref: String,
  sha: String,
) -> Bool {
  store.create_ref(storage, tenant, normalize_ref(ref), sha)
}

pub fn get_ref(
  storage: store.Backend,
  tenant: String,
  ref: String,
) -> Result(String, Nil) {
  store.get_ref(storage, tenant, normalize_ref(ref))
}

pub fn list_refs(
  storage: store.Backend,
  tenant: String,
) -> List(#(String, String)) {
  store.list_refs(storage, tenant)
}

pub fn decode_ref(body: String) -> Result(#(String, String), Nil) {
  let decoder = {
    use ref <- decode.field("ref", decode.string)
    use sha <- decode.field("sha", decode.string)
    decode.success(#(ref, sha))
  }
  json.parse(body, decoder) |> result.replace_error(Nil)
}

pub fn object_response(
  storage: store.Backend,
  base_url: String,
  tenant: String,
  kind: String,
  sha: String,
  body: String,
  recursive: Bool,
) -> Result(json.Json, Nil) {
  case kind {
    "blobs" -> blob_response(base_url, tenant, sha, body)
    "trees" -> tree_response(storage, base_url, tenant, sha, body, recursive)
    "commits" -> commit_response(base_url, tenant, sha, body)
    _ -> Error(Nil)
  }
}

pub fn commit_details_response(
  base_url: String,
  tenant: String,
  sha: String,
  body: String,
) -> Result(json.Json, Nil) {
  use commit <- result.try(decode_commit(body))
  Ok(commit_details_json(base_url, tenant, sha, commit))
}

pub fn commit_history_response(
  storage: store.Backend,
  base_url: String,
  tenant: String,
  sha: String,
  count: Int,
) -> List(json.Json) {
  collect_commit_history(storage, base_url, tenant, sha, count)
}

pub fn ref_response(
  base_url: String,
  tenant: String,
  ref: String,
  sha: String,
) -> json.Json {
  let ref = normalize_ref(ref)
  json.object([
    #("ref", json.string(ref)),
    #(
      "url",
      json.string(
        base_url
        <> "/repos/"
        <> tenant
        <> "/git/refs/"
        <> string.drop_start(ref, 5),
      ),
    ),
    #(
      "object",
      json.object([
        #("type", json.string("commit")),
        #("sha", json.string(sha)),
        #("url", json.string(object_url(base_url, tenant, "commits", sha))),
      ]),
    ),
  ])
}

fn sha1(body: BitArray) -> String {
  crypto.hash(crypto.Sha1, body)
  |> bit_array.base16_encode
  |> string.lowercase
}

fn blob_sha(body: String) -> Result(String, Nil) {
  use blob <- result.try(decode_blob(body))
  use content <- result.try(blob_content(blob.0, blob.1))
  let header_text =
    "blob " <> int.to_string(bit_array.byte_size(content)) <> "\u{0000}"
  let header = bit_array.from_string(header_text)
  Ok(sha1(bit_array.concat([header, content])))
}

fn blob_response(
  base_url: String,
  tenant: String,
  sha: String,
  body: String,
) -> Result(json.Json, Nil) {
  use blob <- result.try(decode_blob(body))
  use content <- result.try(blob_content(blob.0, blob.1))
  let size = bit_array.byte_size(content)
  Ok(
    json.object([
      #("sha", json.string(sha)),
      #("size", json.int(size)),
      #("content", json.string(blob.0)),
      #("encoding", json.string(blob.1)),
      #("url", json.string(object_url(base_url, tenant, "blobs", sha))),
    ]),
  )
}

fn tree_response(
  storage: store.Backend,
  base_url: String,
  tenant: String,
  sha: String,
  body: String,
  recursive: Bool,
) -> Result(json.Json, Nil) {
  use entries <- result.try(decode_tree(body))
  let entries = case recursive {
    True -> flatten_tree(storage, tenant, "", entries, 64)
    False -> entries
  }
  Ok(
    json.object([
      #("sha", json.string(sha)),
      #("url", json.string(object_url(base_url, tenant, "trees", sha))),
      #(
        "tree",
        json.preprocessed_array(
          list.map(entries, fn(entry) {
            json.object([
              #("path", json.string(entry.path)),
              #("mode", json.string(entry.mode)),
              #("type", json.string(entry.kind)),
              #("size", json.int(entry.size)),
              #("sha", json.string(entry.sha)),
              #(
                "url",
                json.string(object_url(
                  base_url,
                  tenant,
                  entry.kind <> "s",
                  entry.sha,
                )),
              ),
            ])
          }),
        ),
      ),
    ]),
  )
}

fn flatten_tree(
  storage: store.Backend,
  tenant: String,
  prefix: String,
  entries: List(TreeEntry),
  depth: Int,
) -> List(TreeEntry) {
  list.flat_map(entries, fn(entry) {
    let path = case prefix {
      "" -> entry.path
      _ -> prefix <> "/" <> entry.path
    }
    let current = TreeEntry(..entry, path: path)
    case entry.kind, depth > 0 {
      "tree", True ->
        case fetch(storage, tenant, entry.sha) {
          Ok(body) ->
            case decode_tree(body) {
              Ok(children) -> [
                current,
                ..flatten_tree(storage, tenant, path, children, depth - 1)
              ]
              Error(_) -> [current]
            }
          Error(_) -> [current]
        }
      _, _ -> [current]
    }
  })
}

fn commit_response(
  base_url: String,
  tenant: String,
  sha: String,
  body: String,
) -> Result(json.Json, Nil) {
  use commit <- result.try(decode_commit(body))
  Ok(
    json.object([
      #("sha", json.string(sha)),
      #("url", json.string(object_url(base_url, tenant, "commits", sha))),
      #("author", person_json(commit.author)),
      #("committer", person_json(commit.committer)),
      #("message", json.string(commit.message)),
      #("tree", commit_hash_json(base_url, tenant, "trees", commit.tree)),
      #(
        "parents",
        json.preprocessed_array(
          list.map(commit.parents, commit_hash_json(
            base_url,
            tenant,
            "commits",
            _,
          )),
        ),
      ),
    ]),
  )
}

fn collect_commit_history(
  storage: store.Backend,
  base_url: String,
  tenant: String,
  sha: String,
  remaining: Int,
) -> List(json.Json) {
  case remaining > 0, fetch(storage, tenant, sha) {
    False, _ -> []
    _, Error(_) -> []
    True, Ok(body) ->
      case decode_commit(body) {
        Error(_) -> []
        Ok(commit) -> [
          commit_details_json(base_url, tenant, sha, commit),
          ..case commit.parents {
            [parent, ..] ->
              collect_commit_history(
                storage,
                base_url,
                tenant,
                parent,
                remaining - 1,
              )
            [] -> []
          }
        ]
      }
  }
}

fn commit_details_json(
  base_url: String,
  tenant: String,
  sha: String,
  commit: Commit,
) -> json.Json {
  let commit_url = object_url(base_url, tenant, "commits", sha)
  json.object([
    #("sha", json.string(sha)),
    #("url", json.string(commit_url)),
    #(
      "commit",
      json.object([
        #("url", json.string(commit_url)),
        #("author", person_json(commit.author)),
        #("committer", person_json(commit.committer)),
        #("message", json.string(commit.message)),
        #("tree", commit_hash_json(base_url, tenant, "trees", commit.tree)),
      ]),
    ),
    #(
      "parents",
      json.preprocessed_array(
        list.map(commit.parents, commit_hash_json(
          base_url,
          tenant,
          "commits",
          _,
        )),
      ),
    ),
  ])
}

fn decode_commit(body: String) -> Result(Commit, Nil) {
  let decoder = {
    use tree <- decode.field("tree", decode.string)
    use parents <- decode.optional_field(
      "parents",
      [],
      decode.list(decode.string),
    )
    use message <- decode.optional_field("message", "", decode.string)
    use author <- decode.field("author", person_decoder())
    use committer <- decode.optional_field(
      "committer",
      author,
      person_decoder(),
    )
    decode.success(Commit(tree, parents, message, author, committer))
  }
  json.parse(body, decoder) |> result.replace_error(Nil)
}

fn tree_entry_decoder() {
  use path <- decode.field("path", decode.string)
  use mode <- decode.optional_field("mode", "100644", decode.string)
  use kind <- decode.optional_field("type", "blob", decode.string)
  use size <- decode.optional_field("size", 0, decode.int)
  use sha <- decode.field("sha", decode.string)
  decode.success(TreeEntry(path, mode, kind, size, sha))
}

fn decode_blob(body: String) -> Result(#(String, String), Nil) {
  let decoder = {
    use content <- decode.field("content", decode.string)
    use encoding <- decode.optional_field("encoding", "utf-8", decode.string)
    decode.success(#(content, encoding))
  }
  json.parse(body, decoder) |> result.replace_error(Nil)
}

fn blob_content(content: String, encoding: String) -> Result(BitArray, Nil) {
  case encoding {
    "base64" -> bit_array.base64_decode(content)
    "utf-8" -> Ok(bit_array.from_string(content))
    _ -> Error(Nil)
  }
}

fn decode_tree(body: String) -> Result(List(TreeEntry), Nil) {
  let decoder = {
    use entries <- decode.field("tree", decode.list(tree_entry_decoder()))
    decode.success(entries)
  }
  json.parse(body, decoder) |> result.replace_error(Nil)
}

fn person_decoder() {
  use name <- decode.optional_field("name", "", decode.string)
  use email <- decode.optional_field("email", "", decode.string)
  use date <- decode.optional_field("date", "", decode.string)
  decode.success(Person(name, email, date))
}

fn person_json(person: Person) -> json.Json {
  json.object([
    #("name", json.string(person.name)),
    #("email", json.string(person.email)),
    #("date", json.string(person.date)),
  ])
}

fn commit_hash_json(
  base_url: String,
  tenant: String,
  kind: String,
  sha: String,
) -> json.Json {
  json.object([
    #("sha", json.string(sha)),
    #("url", json.string(object_url(base_url, tenant, kind, sha))),
  ])
}

fn object_url(
  base_url: String,
  tenant: String,
  kind: String,
  sha: String,
) -> String {
  base_url <> "/repos/" <> tenant <> "/git/" <> kind <> "/" <> sha
}

fn normalize_ref(ref: String) -> String {
  case string.starts_with(ref, "refs/") {
    True -> ref
    False -> "refs/" <> ref
  }
}
