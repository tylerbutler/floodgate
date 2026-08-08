import floodgate/admin_auth
import gleam/option.{None, Some}
import gleeunit/should

// ─────────────────────────────────────────────────────────────────────────────
// Session construction and expiry — deterministic via an injected `now`,
// never a real clock or a sleep.
// ─────────────────────────────────────────────────────────────────────────────

pub fn new_admin_session_expires_after_ttl_test() {
  let session = admin_auth.new_admin_session("user-1", 1000, 60)
  session.user_id |> should.equal("user-1")
  session.created_at |> should.equal(1000)
  session.expires_at |> should.equal(1060)
}

pub fn new_admin_session_id_is_opaque_and_unique_test() {
  let a = admin_auth.new_admin_session("user-1", 1000, 60)
  let b = admin_auth.new_admin_session("user-1", 1000, 60)
  // 256 bits of hex, not derived from user_id/now/ttl.
  { a.id != "" } |> should.be_true
  { a.id != "user-1" } |> should.be_true
  { a.id != b.id } |> should.be_true
}

pub fn session_valid_before_expiry_test() {
  let session = admin_auth.new_admin_session("user-1", 1000, 60)
  admin_auth.session_valid(session, 1059) |> should.be_true
}

pub fn session_invalid_at_or_after_expiry_test() {
  let session = admin_auth.new_admin_session("user-1", 1000, 60)
  admin_auth.session_valid(session, 1060) |> should.be_false
  admin_auth.session_valid(session, 1061) |> should.be_false
}

// ─────────────────────────────────────────────────────────────────────────────
// User construction
// ─────────────────────────────────────────────────────────────────────────────

pub fn new_admin_user_uses_github_id_as_id_test() {
  let user =
    admin_auth.new_admin_user(
      "12345",
      "octocat",
      "The Octocat",
      "octocat@example.com",
      100,
    )
  user.id |> should.equal("12345")
  user.github_username |> should.equal("octocat")
  user.display_name |> should.equal("The Octocat")
  user.email |> should.equal("octocat@example.com")
  user.created_at |> should.equal(100)
}

// ─────────────────────────────────────────────────────────────────────────────
// Allow-list parsing — FLOODGATE_ADMIN_GITHUB_USERS
// ─────────────────────────────────────────────────────────────────────────────

pub fn parse_allowlist_unset_is_none_test() {
  admin_auth.parse_allowlist("") |> should.equal(None)
}

pub fn parse_allowlist_blank_is_none_test() {
  admin_auth.parse_allowlist("   ,  ,") |> should.equal(None)
}

pub fn parse_allowlist_trims_and_drops_blanks_test() {
  admin_auth.parse_allowlist(" alice, bob ,,charlie")
  |> should.equal(Some(["alice", "bob", "charlie"]))
}

// ─────────────────────────────────────────────────────────────────────────────
// GitHub login allow-list decision — the core admin-authorization
// rule. See `admin_auth.github_login_allowed`'s doc comment for the full
// contract.
// ─────────────────────────────────────────────────────────────────────────────

pub fn already_admin_is_always_allowed_test() {
  // Even with an allow-list that no longer includes them, or after another
  // admin already exists — an existing admin never loses access here.
  admin_auth.github_login_allowed(
    github_username: "someone",
    allowlist: Some(["someone-else"]),
    already_admin: True,
    any_admin_exists: True,
  )
  |> should.be_true
}

pub fn no_allowlist_denies_even_when_no_admin_exists_test() {
  admin_auth.github_login_allowed(
    github_username: "first-user",
    allowlist: None,
    already_admin: False,
    any_admin_exists: False,
  )
  |> should.be_false
}

pub fn no_allowlist_and_admin_already_exists_denies_a_different_identity_test() {
  admin_auth.github_login_allowed(
    github_username: "second-user",
    allowlist: None,
    already_admin: False,
    any_admin_exists: True,
  )
  |> should.be_false
}

pub fn allowlist_permits_a_listed_username_test() {
  admin_auth.github_login_allowed(
    github_username: "alice",
    allowlist: Some(["alice", "bob"]),
    already_admin: False,
    any_admin_exists: False,
  )
  |> should.be_true
}

pub fn allowlist_permits_case_insensitively_test() {
  admin_auth.github_login_allowed(
    github_username: "Alice",
    allowlist: Some(["alice"]),
    already_admin: False,
    any_admin_exists: False,
  )
  |> should.be_true
}

pub fn allowlist_denies_an_unlisted_username_test() {
  admin_auth.github_login_allowed(
    github_username: "eve",
    allowlist: Some(["alice", "bob"]),
    already_admin: False,
    any_admin_exists: False,
  )
  |> should.be_false
}

/// An explicit allow-list is authoritative even before any admin exists yet —
/// An allow-listed deployment only permits listed usernames.
pub fn allowlist_denies_unlisted_user_even_with_no_admin_yet_test() {
  admin_auth.github_login_allowed(
    github_username: "random-visitor",
    allowlist: Some(["the-operator"]),
    already_admin: False,
    any_admin_exists: False,
  )
  |> should.be_false
}
