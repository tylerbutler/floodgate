//// Actor-backed in-memory implementation of the Floodgate storage boundary.
////
//// This backend is intentionally independent of ETS. It is useful for tests
//// and embedding, and proves that runtime consumers do not depend on ETS.

import floodgate/store
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/otp/actor
import gleam/otp/static_supervisor
import gleam/otp/supervision

type State {
  State(
    documents: Dict(String, Bool),
    ops: Dict(#(String, Int), String),
    summaries: Dict(String, #(String, Int)),
    objects: Dict(#(String, String), String),
    refs: Dict(#(String, String), String),
  )
}

pub type Msg {
  PutDocument(String, Subject(Nil))
  HasDocument(String, Subject(Bool))
  PutOp(String, Int, String, Subject(Nil))
  GetOps(String, Subject(List(#(Int, String))))
  PutSummary(String, String, Int, Subject(Nil))
  GetSummary(String, Subject(#(String, Int)))
  PutObject(String, String, String, Subject(Nil))
  GetObject(String, String, Subject(Result(String, Nil)))
  PutRef(String, String, String, Subject(Nil))
  CreateRef(String, String, String, Subject(Bool))
  GetRef(String, String, Subject(Result(String, Nil)))
  ListRefs(String, Subject(List(#(String, String))))
}

/// Allocate a fresh name for a memory store actor.
pub fn new_name() -> process.Name(Msg) {
  process.new_name("floodgate_memory_store")
}

/// Start the store actor under `name`.
pub fn start_named(
  name: process.Name(Msg),
) -> Result(actor.Started(Subject(Msg)), actor.StartError) {
  actor.new(State(dict.new(), dict.new(), dict.new(), dict.new(), dict.new()))
  |> actor.on_message(handle)
  |> actor.named(name)
  |> actor.start
}

/// Supervisable child specification for the store actor.
///
/// Unlike `shelf_store`, this backend keeps everything in the actor's state, so
/// a restart starts from empty — there is nothing to rehydrate from. That is
/// still strictly better than the alternative: before this was supervised, the
/// actor's death left every `store.*` call in the runtime timing out forever
/// with nothing to restart it.
pub fn child_spec(
  name: process.Name(Msg),
) -> supervision.ChildSpecification(Subject(Msg)) {
  supervision.worker(fn() { start_named(name) })
}

/// A supervised in-memory backend: the actor is started by the runtime's
/// supervision tree, not here, so `store.supervise` must be applied to the tree
/// before anything calls into the backend.
pub fn supervised() -> store.Backend {
  from_name(new_name())
}

/// A supervised backend over the actor named `name`, which need not be running
/// yet. Callers that need to observe the actor itself — supervision tests —
/// allocate the name with `new_name` and keep it.
pub fn from_name(name: process.Name(Msg)) -> store.Backend {
  backend(name, fn(builder) { static_supervisor.add(builder, child_spec(name)) })
}

/// An *unsupervised* in-memory backend, with the actor started eagerly. For
/// tests and embedding; a runtime should prefer `supervised`.
pub fn new() -> store.Backend {
  let name = new_name()
  let assert Ok(_) = start_named(name)
  backend(name, fn(builder) { builder })
}

/// The storage boundary over the actor registered at `name`.
///
/// Every closure resolves the name at call time rather than capturing a
/// `Subject`, so a supervised restart — which produces a new pid — is invisible
/// to holders of this `Backend`.
fn backend(
  name: process.Name(Msg),
  supervise: fn(static_supervisor.Builder) -> static_supervisor.Builder,
) -> store.Backend {
  let subject = fn() { process.named_subject(name) }

  store.Backend(
    supervise: supervise,
    open: fn() { Nil },
    put_document: fn(topic) {
      process.call(subject(), 1000, PutDocument(topic, _))
    },
    has_document: fn(topic) {
      process.call(subject(), 1000, HasDocument(topic, _))
    },
    put_op: fn(topic, sn, contents) {
      process.call(subject(), 1000, PutOp(topic, sn, contents, _))
    },
    get_ops: fn(topic) { process.call(subject(), 1000, GetOps(topic, _)) },
    put_summary: fn(topic, summary, sn) {
      process.call(subject(), 1000, PutSummary(topic, summary, sn, _))
    },
    get_summary: fn(topic) {
      process.call(subject(), 1000, GetSummary(topic, _))
    },
    put_obj: fn(tenant, sha, data) {
      process.call(subject(), 1000, PutObject(tenant, sha, data, _))
    },
    get_obj: fn(tenant, sha) {
      process.call(subject(), 1000, GetObject(tenant, sha, _))
    },
    put_ref: fn(tenant, ref, sha) {
      process.call(subject(), 1000, PutRef(tenant, ref, sha, _))
    },
    create_ref: fn(tenant, ref, sha) {
      process.call(subject(), 1000, CreateRef(tenant, ref, sha, _))
    },
    get_ref: fn(tenant, ref) {
      process.call(subject(), 1000, GetRef(tenant, ref, _))
    },
    list_refs: fn(tenant) { process.call(subject(), 1000, ListRefs(tenant, _)) },
  )
}

fn handle(state: State, message: Msg) -> actor.Next(State, Msg) {
  case message {
    PutDocument(topic, reply) -> {
      process.send(reply, Nil)
      actor.continue(
        State(..state, documents: dict.insert(state.documents, topic, True)),
      )
    }
    HasDocument(topic, reply) -> {
      process.send(reply, dict.has_key(state.documents, topic))
      actor.continue(state)
    }
    PutOp(topic, sn, contents, reply) -> {
      process.send(reply, Nil)
      actor.continue(
        State(..state, ops: dict.insert(state.ops, #(topic, sn), contents)),
      )
    }
    GetOps(topic, reply) -> {
      let ops =
        state.ops
        |> dict.to_list
        |> list.filter_map(fn(entry) {
          let #(#(stored_topic, sn), contents) = entry
          case stored_topic == topic {
            True -> Ok(#(sn, contents))
            False -> Error(Nil)
          }
        })
      process.send(reply, ops)
      actor.continue(state)
    }
    PutSummary(topic, summary, sn, reply) -> {
      process.send(reply, Nil)
      actor.continue(
        State(
          ..state,
          summaries: dict.insert(state.summaries, topic, #(summary, sn)),
        ),
      )
    }
    GetSummary(topic, reply) -> {
      process.send(
        reply,
        dict.get(state.summaries, topic) |> result_or(#("", 0)),
      )
      actor.continue(state)
    }
    PutObject(tenant, sha, data, reply) -> {
      process.send(reply, Nil)
      actor.continue(
        State(
          ..state,
          objects: dict.insert(state.objects, #(tenant, sha), data),
        ),
      )
    }
    GetObject(tenant, sha, reply) -> {
      process.send(reply, dict.get(state.objects, #(tenant, sha)))
      actor.continue(state)
    }
    PutRef(tenant, ref, sha, reply) -> {
      process.send(reply, Nil)
      actor.continue(
        State(..state, refs: dict.insert(state.refs, #(tenant, ref), sha)),
      )
    }
    CreateRef(tenant, ref, sha, reply) -> {
      let key = #(tenant, ref)
      case dict.has_key(state.refs, key) {
        True -> {
          process.send(reply, False)
          actor.continue(state)
        }
        False -> {
          process.send(reply, True)
          actor.continue(
            State(..state, refs: dict.insert(state.refs, key, sha)),
          )
        }
      }
    }
    GetRef(tenant, ref, reply) -> {
      process.send(reply, dict.get(state.refs, #(tenant, ref)))
      actor.continue(state)
    }
    ListRefs(tenant, reply) -> {
      let refs =
        state.refs
        |> dict.to_list
        |> list.filter_map(fn(entry) {
          let #(#(stored_tenant, ref), sha) = entry
          case stored_tenant == tenant {
            True -> Ok(#(ref, sha))
            False -> Error(Nil)
          }
        })
      process.send(reply, refs)
      actor.continue(state)
    }
  }
}

fn result_or(result: Result(a, Nil), default: a) -> a {
  case result {
    Ok(value) -> value
    Error(Nil) -> default
  }
}
