//// Topic → document-actor lookup, backed by a public ETS table.
////
//// This is the piece gleam_erlang does not provide. `process.Name` is the only
//// built-in way to find a process by a stable identifier, and `new_name/1`
//// mints an atom per call — the docs warn that dynamic use fills the atom table
//// and crashes the VM — so document ids, which are client-supplied and
//// unbounded, cannot name actors. Elixir solves this for Levee with `Registry`;
//// this is the same solution with a smaller surface.
////
//// The point of the ETS table rather than a lookup actor is that reads happen
//// **in the calling process**. Resolving a document costs no message hop, so
//// there is no global mailbox left on the hot path — which is the whole reason
//// for splitting the session actor per document.
////
//// Writes come from two places, and neither races the other:
////
//// - the registry owner inserts a row after starting a document actor. Because
////   inserts are serialized in that one process, get-or-start is atomic and the
////   `{:error, {:already_started, pid}}` branch Levee's `documents/registry.ex`
////   needs cannot arise here.
//// - a document actor deletes its own row as it shuts down. It is the only
////   writer for its own key, and the owner's monitor is an idempotent backstop
////   that re-checks the stored subject before deleting.
////
//// Generic in the stored message type so `floodgate/doc_actor` can delete its
//// own row without this module having to name it — that would be a cycle.

import gleam/erlang/atom.{type Atom}
import gleam/erlang/process.{type Subject}

pub opaque type Registry(msg) {
  Registry(table: Atom)
}

/// Derive the registry from the owner's registered name.
///
/// Reusing that atom is deliberate: it is allocated once per instance by
/// `process.new_name`, so the table name costs nothing new, stays the same
/// across an owner restart, and differs between independently started sessions
/// — which the test suite relies on, since it starts many on one node.
pub fn from_name(name: process.Name(owner_msg)) -> Registry(msg) {
  Registry(table_name(name))
}

/// Create the table if it is not already there. Called by the owner as it
/// starts; idempotent so an owner restart can recreate it.
pub fn open(registry: Registry(msg)) -> Nil {
  new(registry.table)
}

pub fn insert(
  registry: Registry(msg),
  topic: String,
  subject: Subject(msg),
) -> Nil {
  do_insert(registry.table, topic, subject)
}

/// Resolve a document actor. A miss means "no actor", not "no document" — the
/// document may be entirely cold, in which case callers that only read answer
/// from storage instead of starting one.
pub fn lookup(
  registry: Registry(msg),
  topic: String,
) -> Result(Subject(msg), Nil) {
  do_lookup(registry.table, topic)
}

pub fn delete(registry: Registry(msg), topic: String) -> Nil {
  do_delete(registry.table, topic)
}

/// How many documents currently have an actor. Read straight from ETS, so this
/// costs no process call.
pub fn size(registry: Registry(msg)) -> Int {
  do_size(registry.table)
}

@external(erlang, "floodgate_registry_ffi", "table_name")
fn table_name(name: process.Name(owner_msg)) -> Atom

@external(erlang, "floodgate_registry_ffi", "new")
fn new(table: Atom) -> Nil

@external(erlang, "floodgate_registry_ffi", "insert")
fn do_insert(table: Atom, topic: String, subject: Subject(msg)) -> Nil

@external(erlang, "floodgate_registry_ffi", "lookup")
fn do_lookup(table: Atom, topic: String) -> Result(Subject(msg), Nil)

@external(erlang, "floodgate_registry_ffi", "delete")
fn do_delete(table: Atom, topic: String) -> Nil

@external(erlang, "floodgate_registry_ffi", "size")
fn do_size(table: Atom) -> Int
