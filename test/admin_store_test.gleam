import floodgate
import floodgate/admin_auth
import floodgate/memory_store
import floodgate/shelf_store
import floodgate/store
import gleam/bit_array
import gleam/crypto
import gleeunit/should

/// A fresh, unique on-disk data directory so each run starts from empty DETS —
/// see `tenant_store_test.unique_dir` for why.
fn unique_dir() -> String {
  "build/floodgate_admin_store_test/"
  <> { crypto.strong_random_bytes(8) |> bit_array.base16_encode }
}

pub fn shelf_backend_satisfies_admin_user_and_session_boundary_test() {
  assert_admin_backend_contract(shelf_store.new(unique_dir()))
}

pub fn memory_backend_satisfies_admin_user_and_session_boundary_test() {
  assert_admin_backend_contract(memory_store.new())
}

/// The same contract, run against both backends, matching
/// `tenant_store_test.assert_tenant_backend_contract`'s pattern.
fn assert_admin_backend_contract(backend: store.Backend) -> Nil {
  // Unknown users/sessions report absence consistently.
  store.get_admin_user(backend, "no-such-github-id") |> should.equal(Error(Nil))
  store.get_admin_session(backend, "no-such-session")
  |> should.equal(Error(Nil))
  store.admin_user_count(backend) |> should.equal(0)

  // Put + get round-trips every field, keyed by the GitHub id (`user.id`).
  let user =
    admin_auth.new_admin_user(
      "1001",
      "octocat",
      "The Octocat",
      "oc@example.com",
      100,
    )
  store.put_admin_user(backend, user)
  store.get_admin_user(backend, "1001") |> should.equal(Ok(user))
  store.admin_user_count(backend) |> should.equal(1)

  // A second, distinct user is independent and is reflected in the count.
  let other = admin_auth.new_admin_user("2002", "other", "Other User", "", 200)
  store.put_admin_user(backend, other)
  store.admin_user_count(backend) |> should.equal(2)
  store.get_admin_user(backend, "1001") |> should.equal(Ok(user))
  store.get_admin_user(backend, "2002") |> should.equal(Ok(other))

  // put_admin_user overwrites by id rather than duplicating.
  let updated_user =
    admin_auth.new_admin_user(
      "1001",
      "octocat",
      "Updated Name",
      "oc@example.com",
      100,
    )
  store.put_admin_user(backend, updated_user)
  store.get_admin_user(backend, "1001") |> should.equal(Ok(updated_user))
  store.admin_user_count(backend) |> should.equal(2)

  // Sessions: put + get round-trips, delete forgets it.
  let session = admin_auth.new_admin_session("1001", 1000, 604_800)
  store.put_admin_session(backend, session)
  store.get_admin_session(backend, session.id) |> should.equal(Ok(session))

  store.delete_admin_session(backend, session.id)
  store.get_admin_session(backend, session.id) |> should.equal(Error(Nil))

  // Deleting an already-absent session is a no-op, not an error.
  store.delete_admin_session(backend, "never-existed")
}

/// The shelf backend keeps admin users and sessions across a restart,
/// simulated by re-opening the same data directory — matching
/// `tenant_store_test.shelf_backend_persists_tenant_lifecycle_across_restart_test`.
pub fn shelf_backend_persists_admin_users_and_sessions_across_restart_test() {
  let dir = unique_dir()
  let backend = shelf_store.new(dir)
  let user =
    admin_auth.new_admin_user(
      "3003",
      "persisted",
      "Persisted Admin",
      "p@example.com",
      100,
    )
  store.put_admin_user(backend, user)
  let session = admin_auth.new_admin_session("3003", 1000, 604_800)
  store.put_admin_session(backend, session)

  let reopened = shelf_store.new(dir)
  store.get_admin_user(reopened, "3003") |> should.equal(Ok(user))
  store.get_admin_session(reopened, session.id) |> should.equal(Ok(session))
  store.admin_user_count(reopened) |> should.equal(1)
}

pub fn cookie_session_authorizes_admin_api_test() {
  let backend = memory_store.new()
  let user =
    admin_auth.new_admin_user(
      "cookie-user",
      "octocat",
      "Octocat",
      "octocat@example.com",
      1000,
    )
  let session = admin_auth.new_admin_session(user.id, 1000, 60)
  store.put_admin_user(backend, user)
  store.put_admin_session(backend, session)

  floodgate.admin_credentials_authorized(
    Error(Nil),
    Ok(session.id),
    "",
    backend,
    1059,
  )
  |> should.be_true
}

pub fn expired_cookie_session_does_not_authorize_admin_api_test() {
  let backend = memory_store.new()
  let user =
    admin_auth.new_admin_user(
      "expired-user",
      "octocat",
      "Octocat",
      "octocat@example.com",
      1000,
    )
  let session = admin_auth.new_admin_session(user.id, 1000, 60)
  store.put_admin_user(backend, user)
  store.put_admin_session(backend, session)

  floodgate.admin_credentials_authorized(
    Error(Nil),
    Ok(session.id),
    "",
    backend,
    1060,
  )
  |> should.be_false
}
