//// Typed storage boundary for documents, ops, summaries, and Historian data.
////
//// A backend is a value, rather than a process-global selection, so a complete
//// Floodgate runtime can be constructed from any implementation. Concrete
//// backends: `floodgate/shelf_store` (shelf typed ETS + DETS, the default) and
//// `floodgate/memory_store` (actor-backed, for tests).

import gleam/int
import gleam/list
import gleam/otp/static_supervisor
import gleam/string

pub type Backend {
  Backend(
    /// Add whatever processes this backend needs to the runtime's supervision
    /// tree. Identity for a backend that owns no process.
    ///
    /// The field is a builder transform rather than a child specification
    /// because `ChildSpecification` is parameterized on the child's own subject
    /// type, which differs per backend; a transform erases that difference
    /// without giving up the supervisor's type safety at the `add` site.
    supervise: fn(static_supervisor.Builder) -> static_supervisor.Builder,
    open: fn() -> Nil,
    put_document: fn(String) -> Nil,
    has_document: fn(String) -> Bool,
    put_op: fn(String, Int, String) -> Nil,
    get_ops: fn(String) -> List(#(Int, String)),
    put_summary: fn(String, String, Int) -> Nil,
    get_summary: fn(String) -> #(String, Int),
    put_obj: fn(String, String, String) -> Nil,
    get_obj: fn(String, String) -> Result(String, Nil),
    put_ref: fn(String, String, String) -> Nil,
    create_ref: fn(String, String, String) -> Bool,
    get_ref: fn(String, String) -> Result(String, Nil),
    list_refs: fn(String) -> List(#(String, String)),
  )
}

/// Add the backend's own processes to a supervision tree under construction.
pub fn supervise(
  builder: static_supervisor.Builder,
  backend: Backend,
) -> static_supervisor.Builder {
  backend.supervise(builder)
}

pub fn open(backend: Backend) -> Nil {
  backend.open()
}

pub fn put_document(backend: Backend, topic: String) -> Nil {
  backend.put_document(topic)
}

pub fn has_document(backend: Backend, topic: String) -> Bool {
  backend.has_document(topic)
}

pub fn put_op(
  backend: Backend,
  topic: String,
  sequence_number: Int,
  contents: String,
) -> Nil {
  backend.put_op(topic, sequence_number, contents)
}

/// Operations are always returned in sequence order, independent of backend.
pub fn get_ops(backend: Backend, topic: String) -> List(#(Int, String)) {
  backend.get_ops(topic)
  |> list.sort(fn(left, right) { int.compare(left.0, right.0) })
}

pub fn put_summary(
  backend: Backend,
  topic: String,
  handle: String,
  sequence_number: Int,
) -> Nil {
  backend.put_summary(topic, handle, sequence_number)
}

pub fn get_summary(backend: Backend, topic: String) -> #(String, Int) {
  backend.get_summary(topic)
}

pub fn put_obj(
  backend: Backend,
  tenant: String,
  sha: String,
  data: String,
) -> Nil {
  backend.put_obj(tenant, sha, data)
}

pub fn get_obj(
  backend: Backend,
  tenant: String,
  sha: String,
) -> Result(String, Nil) {
  backend.get_obj(tenant, sha)
}

pub fn put_ref(
  backend: Backend,
  tenant: String,
  ref: String,
  sha: String,
) -> Nil {
  backend.put_ref(tenant, ref, sha)
}

pub fn create_ref(
  backend: Backend,
  tenant: String,
  ref: String,
  sha: String,
) -> Bool {
  backend.create_ref(tenant, ref, sha)
}

pub fn get_ref(
  backend: Backend,
  tenant: String,
  ref: String,
) -> Result(String, Nil) {
  backend.get_ref(tenant, ref)
}

/// References are always returned in path order, independent of backend.
pub fn list_refs(backend: Backend, tenant: String) -> List(#(String, String)) {
  backend.list_refs(tenant)
  |> list.sort(fn(left, right) { string.compare(left.0, right.0) })
}
