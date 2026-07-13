//// Typed storage boundary for documents, ops, summaries, and Historian data.
////
//// A backend is a value, rather than a process-global selection, so a complete
//// Floodgate runtime can be constructed with ETS today and PostgreSQL later.

import gleam/int
import gleam/list
import gleam/string

pub type Backend {
  Backend(
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

/// The default VM-lifetime ETS backend.
pub fn ets() -> Backend {
  Backend(
    open: ets_open,
    put_document: ets_put_document,
    has_document: ets_has_document,
    put_op: ets_put_op,
    get_ops: ets_get_ops,
    put_summary: ets_put_summary,
    get_summary: ets_get_summary,
    put_obj: ets_put_obj,
    get_obj: ets_get_obj,
    put_ref: ets_put_ref,
    create_ref: ets_create_ref,
    get_ref: ets_get_ref,
    list_refs: ets_list_refs,
  )
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

@external(erlang, "floodgate_store_ffi", "open")
fn ets_open() -> Nil

@external(erlang, "floodgate_store_ffi", "put_document")
fn ets_put_document(topic: String) -> Nil

@external(erlang, "floodgate_store_ffi", "has_document")
fn ets_has_document(topic: String) -> Bool

@external(erlang, "floodgate_store_ffi", "put_op")
fn ets_put_op(topic: String, sn: Int, contents: String) -> Nil

@external(erlang, "floodgate_store_ffi", "get_ops")
fn ets_get_ops(topic: String) -> List(#(Int, String))

@external(erlang, "floodgate_store_ffi", "put_summary")
fn ets_put_summary(topic: String, handle: String, sn: Int) -> Nil

@external(erlang, "floodgate_store_ffi", "get_summary")
fn ets_get_summary(topic: String) -> #(String, Int)

@external(erlang, "floodgate_store_ffi", "put_obj")
fn ets_put_obj(tenant: String, sha: String, data: String) -> Nil

@external(erlang, "floodgate_store_ffi", "get_obj")
fn ets_get_obj(tenant: String, sha: String) -> Result(String, Nil)

@external(erlang, "floodgate_store_ffi", "put_ref")
fn ets_put_ref(tenant: String, ref: String, sha: String) -> Nil

@external(erlang, "floodgate_store_ffi", "create_ref")
fn ets_create_ref(tenant: String, ref: String, sha: String) -> Bool

@external(erlang, "floodgate_store_ffi", "get_ref")
fn ets_get_ref(tenant: String, ref: String) -> Result(String, Nil)

@external(erlang, "floodgate_store_ffi", "list_refs")
fn ets_list_refs(tenant: String) -> List(#(String, String))
