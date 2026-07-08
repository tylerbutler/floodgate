import gleeunit
import gleeunit/should
import floodgate
import floodgate/git
import floodgate/session

pub fn main() {
  gleeunit.main()
}

pub fn start_registers_channel_test() {
  let assert Ok(_) = floodgate.start()
  floodgate.topic_prefix |> should.equal("document:")
}

pub fn session_sequences_per_document_test() {
  let s = session.start()
  session.join(s, "document:t:seqbasic", "c1")
  let assert session.Assigned(1, _) =
    session.submit(s, "document:t:seqbasic", "c1", 1, 0, "a")
  let assert session.Assigned(2, _) =
    session.submit(s, "document:t:seqbasic", "c1", 2, 0, "b")
}

pub fn since_returns_history_after_sn_test() {
  let s = session.start()
  session.join(s, "document:t:since", "c1")
  let assert session.Assigned(1, _) =
    session.submit(s, "document:t:since", "c1", 1, 0, "a")
  let assert session.Assigned(2, _) =
    session.submit(s, "document:t:since", "c1", 2, 0, "b")
  session.since(s, "document:t:since", 1) |> should.equal([#(2, "b")])
}

pub fn summary_stores_latest_handle_test() {
  let s = session.start()
  session.set_summary(s, "document:t:d2", "sha-abc", 5)
  session.summary(s, "document:t:d2") |> should.equal(#("sha-abc", 5))
}

pub fn ops_persist_across_session_restart_test() {
  let s1 = session.start()
  session.join(s1, "document:t:persist", "c1")
  let assert session.Assigned(_, _) =
    session.submit(s1, "document:t:persist", "c1", 1, 0, "DURABLE")
  // A fresh session actor (ETS-backed store) still sees the op.
  let s2 = session.start()
  session.since(s2, "document:t:persist", 0) |> should.equal([#(1, "DURABLE")])
}

pub fn sequence_continues_after_session_restart_test() {
  let s1 = session.start()
  session.join(s1, "document:t:resume", "c1")
  let assert session.Assigned(1, _) =
    session.submit(s1, "document:t:resume", "c1", 1, 0, "x")
  // Fresh actor resumes numbering after the last persisted SN.
  let s2 = session.start()
  session.join(s2, "document:t:resume", "c2")
  let assert session.Assigned(2, _) =
    session.submit(s2, "document:t:resume", "c2", 1, 0, "y")
}

pub fn git_create_fetch_roundtrip_test() {
  let sha = git.create("t", "{\"content\":\"hi\"}")
  git.fetch("t", sha) |> should.equal(Ok("{\"content\":\"hi\"}"))
  git.fetch("t", "nope") |> should.equal(Error(Nil))
}
