//// Content-addressed storage for blobs, trees, commits, and refs.
////
//// A thin adapter over the shared `silt` library (git object model + REST
//// response shapes) and floodgate's own `store.Backend`. `silt` owns the
//// hashing, serialization, and response shaping; this module wires those to
//// persistence and the tenant/store closure. See Levee ADR-006.

import floodgate/store
import gleam/json
import gleam/result
import silt/object
import silt/rest

/// Store an object's raw body, returning its content-addressed id.
///
/// Objects are stored per **document**, not per tenant: a blob belongs to the
/// document whose summary tree reaches it. Callers on the tenant-scoped
/// Historian routes take `document_id` from their token claims, which is the
/// only place the association is recorded. The cost is that two documents in a
/// tenant uploading identical bytes store them twice; the gain is that a
/// document's storage is self-contained.
pub fn create(
  storage: store.Backend,
  topic: String,
  kind: String,
  body: String,
) -> Result(String, Nil) {
  use sha <- result.try(object.object_id(kind, body))
  use Nil <- result.try(store.put_object(storage, topic, sha, body))
  Ok(sha)
}

/// Fetch an object's raw body by SHA, within a document. An object written
/// under a different document is not visible here — see `create`.
pub fn fetch(
  storage: store.Backend,
  topic: String,
  sha: String,
) -> Result(String, Nil) {
  store.get_object(storage, topic, sha)
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

/// Publish a document's summary commit.
///
/// Always written *after* the session's own summary pointer, so the only state a
/// crash can leave is a ref that lags. That direction is safe: a client
/// discovering an older snapshot replays more ops, which is what loading any
/// older version does anyway. The reverse — ref ahead of the summary pointer —
/// would have a client load a snapshot and then replay ops already inside it.
pub fn publish_summary_ref(
  storage: store.Backend,
  tenant: String,
  document_id: String,
  sha: String,
) -> Result(Nil, Nil) {
  put_ref(storage, tenant, summary_ref(document_id), sha)
}

/// Write the summary ref if it is missing, leaving an existing one alone.
///
/// Repairs the one crash prefix that is not benign: a summary pointer written
/// with no ref at all, which makes `GET /commits?sha=<documentId>` fall through
/// to treating the document id as a sha and fail, so the document cannot be
/// loaded. A ref that merely lags is left as-is — it is safe, self-heals on the
/// next summary, and a client is free to move refs through the Historian API.
pub fn ensure_summary_ref(
  storage: store.Backend,
  tenant: String,
  document_id: String,
  sha: String,
) -> Result(Nil, Nil) {
  case get_ref(storage, tenant, summary_ref(document_id)) {
    Ok(_) -> Ok(Nil)
    Error(Nil) -> publish_summary_ref(storage, tenant, document_id, sha)
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

/// A `silt.Fetch` closing over this stack's store and document, so `silt` can
/// walk child objects (recursive trees, commit history) without owning
/// persistence. The walk stays inside one document, which is exactly the set of
/// objects that document's storage holds.
fn fetcher(storage: store.Backend, topic: String) -> rest.Fetch {
  fn(sha) { store.get_object(storage, topic, sha) }
}
