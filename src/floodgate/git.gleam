//// Content-addressed storage for blobs, trees, commits, and refs.
////
//// A thin adapter over the shared `silt` library (git object model + REST
//// response shapes) and floodgate's own `store.Backend`. `silt` owns the
//// hashing, serialization, and response shaping; this module wires those to
//// persistence and the tenant/store closure. See Levee ADR-006.

import floodgate/store
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set
import gleam/string
import silt/object
import silt/rest

pub type PublicationError {
  StorageUnavailable
  CorruptPublication(reason: String)
}

/// Only recovery may use this tenant fallback. Its head must come from the
/// stored pointer or a validated server acknowledgement, never a request/ref.
pub fn recovery_chain(
  storage: store.Backend,
  topic: String,
  head: String,
) -> Result(List(#(String, String)), PublicationError) {
  collect_chain(storage, topic, head, fetch(storage, topic, _), set.new(), [])
}

fn collect_chain(
  storage: store.Backend,
  topic: String,
  sha: String,
  fetch_commit: rest.Fetch,
  seen: set.Set(String),
  collected: List(#(String, String)),
) -> Result(List(#(String, String)), PublicationError) {
  use Nil <- result.try(case set.contains(seen, sha) {
    True -> Error(CorruptPublication("Cycle in published commit history"))
    False -> Ok(Nil)
  })
  use body <- result.try(
    fetch_commit(sha)
    |> result.replace_error(CorruptPublication("Published commit is missing")),
  )
  use Nil <- result.try(case object.object_id("commits", body) == Ok(sha) {
    True -> Ok(Nil)
    False -> Error(CorruptPublication("Published commit hash does not match"))
  })
  use commit <- result.try(
    object.decode_commit(body)
    |> result.replace_error(CorruptPublication("Published commit is invalid")),
  )
  use tree <- result.try(
    fetch(storage, topic, commit.tree)
    |> result.replace_error(CorruptPublication("Published root tree is missing")),
  )
  use _ <- result.try(
    object.decode_tree(tree)
    |> result.replace_error(CorruptPublication("Published root tree is invalid")),
  )
  let collected = [#(sha, body), ..collected]
  case commit.parents {
    [] -> Ok(list.reverse(collected))
    [parent, ..] ->
      collect_chain(
        storage,
        topic,
        parent,
        fetch_commit,
        set.insert(seen, sha),
        collected,
      )
  }
}

/// Store an object's raw body, returning its content-addressed id.
///
/// Objects are stored per tenant, matching Historian's content-addressed object
/// namespace. Routerlicious drivers cache uploaded hashes across documents and
/// may reuse an existing object without uploading it again.
pub fn create(
  storage: store.Backend,
  topic: String,
  kind: String,
  body: String,
) -> Result(String, Nil) {
  use sha <- result.try(object.object_id(kind, body))
  use Nil <- result.try(store.put_object(
    storage,
    object_namespace(topic),
    sha,
    body,
  ))
  Ok(sha)
}

/// Fetch an object's raw body by SHA within a tenant.
///
/// The document-scoped fallback preserves objects written by older Floodgate
/// releases while new writes use the Routerlicious-compatible tenant scope.
pub fn fetch(
  storage: store.Backend,
  topic: String,
  sha: String,
) -> Result(String, Nil) {
  case store.get_object(storage, object_namespace(topic), sha) {
    Ok(body) -> Ok(body)
    Error(Nil) -> store.get_object(storage, topic, sha)
  }
}

pub fn put_ref(
  storage: store.Backend,
  tenant: String,
  ref: String,
  sha: String,
) -> Result(Nil, Nil) {
  store.put_ref(storage, tenant, rest.normalize_ref(ref), sha)
}

/// `Ok(False)` when the ref already exists with a different sha; `Error(Nil)`
/// when storage itself failed.
pub fn create_ref(
  storage: store.Backend,
  tenant: String,
  ref: String,
  sha: String,
) -> Result(Bool, Nil) {
  store.create_ref(storage, tenant, rest.normalize_ref(ref), sha)
}

pub fn get_ref(
  storage: store.Backend,
  tenant: String,
  ref: String,
) -> Result(String, Nil) {
  store.get_ref(storage, tenant, rest.normalize_ref(ref))
}

/// The ref a document's latest summary commit is published under. `GET /commits`
/// resolves `?sha=<documentId>` through it, so it is how a loading client
/// discovers the newest snapshot.
pub fn summary_ref(document_id: String) -> String {
  "refs/heads/" <> document_id
}

/// Publish the actor's summary pointer after its durable proposal and response.
pub fn publish_summary_ref(
  storage: store.Backend,
  tenant: String,
  document_id: String,
  sha: String,
) -> Result(Nil, Nil) {
  put_ref(storage, tenant, summary_ref(document_id), sha)
}

/// Reconcile the server-owned ref under the document actor's ownership.
pub fn reconcile_summary_ref(
  storage: store.Backend,
  tenant: String,
  document_id: String,
  summary: Option(#(String, Int)),
) -> Result(Nil, Nil) {
  case summary {
    None -> store.delete_ref(storage, tenant, summary_ref(document_id))
    Some(#(sha, _)) ->
      case get_ref(storage, tenant, summary_ref(document_id)) {
        Ok(existing) if existing == sha -> Ok(Nil)
        _ -> publish_summary_ref(storage, tenant, document_id, sha)
      }
  }
}

pub fn head_document(ref: String) -> Option(String) {
  let normalized = rest.normalize_ref(ref)
  case string.starts_with(normalized, "refs/heads/") {
    True -> Some(string.drop_start(normalized, 11))
    False -> None
  }
}

pub fn list_refs(
  storage: store.Backend,
  tenant: String,
) -> List(#(String, String)) {
  store.list_refs(storage, tenant)
}

pub fn decode_ref(body: String) -> Result(#(String, String), Nil) {
  object.decode_ref(body)
}

pub fn object_response(
  storage: store.Backend,
  base_url: String,
  tenant: String,
  topic: String,
  kind: String,
  sha: String,
  body: String,
  recursive: Bool,
) -> Result(json.Json, Nil) {
  rest.object_response(
    base_url,
    tenant,
    kind,
    sha,
    body,
    recursive,
    fetcher(storage, topic),
  )
}

pub fn commit_details_response(
  base_url: String,
  tenant: String,
  sha: String,
  body: String,
) -> Result(json.Json, Nil) {
  rest.commit_details_response(base_url, tenant, sha, body)
}

pub fn commit_history_response(
  storage: store.Backend,
  base_url: String,
  tenant: String,
  topic: String,
  sha: String,
  count: Int,
) -> List(json.Json) {
  rest.commit_history_response(
    base_url,
    tenant,
    sha,
    count,
    fetcher(storage, topic),
  )
}

pub fn ref_response(
  base_url: String,
  tenant: String,
  ref: String,
  sha: String,
) -> json.Json {
  rest.ref_response(base_url, tenant, ref, sha)
}

/// A `silt.Fetch` closing over this stack's store and tenant, so `silt` can
/// walk child objects (recursive trees, commit history) without owning
/// persistence.
fn fetcher(storage: store.Backend, topic: String) -> rest.Fetch {
  fn(sha) { fetch(storage, topic, sha) }
}

fn object_namespace(topic: String) -> String {
  case string.split(topic, ":") {
    ["document", tenant, ..] -> tenant
    _ -> topic
  }
}
