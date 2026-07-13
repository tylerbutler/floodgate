//// Actor-backed in-memory implementation of the Floodgate storage boundary.
////
//// This backend is intentionally independent of ETS. It is useful for tests
//// and embedding, and proves that runtime consumers do not depend on ETS.

import floodgate/store
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/otp/actor

type State {
  State(
    documents: Dict(String, Bool),
    ops: Dict(#(String, Int), String),
    summaries: Dict(String, #(String, Int)),
    objects: Dict(#(String, String), String),
    refs: Dict(#(String, String), String),
  )
}

type Msg {
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

pub fn new() -> store.Backend {
  let initial =
    State(dict.new(), dict.new(), dict.new(), dict.new(), dict.new())
  let assert Ok(started) =
    actor.new(initial) |> actor.on_message(handle) |> actor.start
  let subject = started.data

  store.Backend(
    open: fn() { Nil },
    put_document: fn(topic) {
      process.call(subject, 1000, PutDocument(topic, _))
    },
    has_document: fn(topic) {
      process.call(subject, 1000, HasDocument(topic, _))
    },
    put_op: fn(topic, sn, contents) {
      process.call(subject, 1000, PutOp(topic, sn, contents, _))
    },
    get_ops: fn(topic) { process.call(subject, 1000, GetOps(topic, _)) },
    put_summary: fn(topic, summary, sn) {
      process.call(subject, 1000, PutSummary(topic, summary, sn, _))
    },
    get_summary: fn(topic) { process.call(subject, 1000, GetSummary(topic, _)) },
    put_obj: fn(tenant, sha, data) {
      process.call(subject, 1000, PutObject(tenant, sha, data, _))
    },
    get_obj: fn(tenant, sha) {
      process.call(subject, 1000, GetObject(tenant, sha, _))
    },
    put_ref: fn(tenant, ref, sha) {
      process.call(subject, 1000, PutRef(tenant, ref, sha, _))
    },
    create_ref: fn(tenant, ref, sha) {
      process.call(subject, 1000, CreateRef(tenant, ref, sha, _))
    },
    get_ref: fn(tenant, ref) {
      process.call(subject, 1000, GetRef(tenant, ref, _))
    },
    list_refs: fn(tenant) { process.call(subject, 1000, ListRefs(tenant, _)) },
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
