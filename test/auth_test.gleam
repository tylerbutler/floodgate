import floodgate/auth
import gleeunit/should

pub fn extracts_routerlicious_basic_token_test() {
  auth.extract_token("Basic abc.def.ghi")
  |> should.equal(Ok("abc.def.ghi"))
}

pub fn extracts_routerlicious_storage_credentials_test() {
  auth.extract_token("Basic Zmx1aWQ6YWJjLmRlZi5naGk=")
  |> should.equal(Ok("abc.def.ghi"))
}

pub fn extracts_bearer_token_test() {
  auth.extract_token("Bearer abc.def.ghi")
  |> should.equal(Ok("abc.def.ghi"))
}

pub fn rejects_invalid_authorization_scheme_test() {
  auth.extract_token("Digest abc.def.ghi")
  |> should.equal(Error(auth.BadFormat))
}

pub fn minted_token_verifies_with_strict_claims_test() {
  let token =
    auth.mint_token(
      "fluid",
      "doc-1",
      ["doc:read", "doc:write"],
      "user-1",
      "tenant-secret",
      100,
      3600,
    )
  let assert Ok(claims) =
    auth.verify(token, "tenant-secret", "fluid", "doc-1", 101)
  claims.tenant_id |> should.equal("fluid")
  claims.document_id |> should.equal("doc-1")
  claims.user.id |> should.equal("user-1")
  claims.version |> should.equal("1.0")
}

pub fn minted_token_rejects_wrong_or_empty_key_test() {
  let token =
    auth.mint_token(
      "fluid",
      "doc-1",
      ["doc:read"],
      "user-1",
      "tenant-secret",
      100,
      3600,
    )
  auth.verify(token, "wrong-secret", "fluid", "doc-1", 101)
  |> should.equal(Error(auth.BadSignature))
  auth.verify(token, "", "fluid", "doc-1", 101)
  |> should.equal(Error(auth.BadSignature))
}

pub fn token_mint_requires_separate_bearer_credential_test() {
  auth.verify_token_mint_authorization("Bearer mint-secret", "mint-secret")
  |> should.equal(Ok(Nil))
  auth.verify_token_mint_authorization("Bearer wrong-secret", "mint-secret")
  |> should.equal(Error(auth.BadSignature))
  auth.verify_token_mint_authorization("Basic mint-secret", "mint-secret")
  |> should.equal(Error(auth.BadFormat))
}

pub fn admin_authorization_requires_separate_bearer_credential_test() {
  auth.verify_admin_authorization("Bearer admin-key", "admin-key")
  |> should.equal(Ok(Nil))
  auth.verify_admin_authorization("Bearer wrong-key", "admin-key")
  |> should.equal(Error(auth.BadSignature))
  auth.verify_admin_authorization("Basic admin-key", "admin-key")
  |> should.equal(Error(auth.BadFormat))
  // An unset admin key (empty string) never matches, even a non-empty
  // token — otherwise a deployment that never set FLOODGATE_ADMIN_KEY would
  // accept any credential.
  auth.verify_admin_authorization("Bearer anything", "")
  |> should.equal(Error(auth.BadFormat))
}

/// The mint credential and the admin key are independent secrets: one does
/// not authorize the other's endpoint.
pub fn admin_and_token_mint_credentials_do_not_cross_authorize_test() {
  auth.verify_admin_authorization("Bearer mint-secret", "admin-key")
  |> should.equal(Error(auth.BadSignature))
  auth.verify_token_mint_authorization("Bearer admin-key", "mint-secret")
  |> should.equal(Error(auth.BadSignature))
}

// ─────────────────────────────────────────────────────────────────────────────
// Per-tenant verification (`_any`) — levee's try-both-slots rotation semantics
// ─────────────────────────────────────────────────────────────────────────────

pub fn verify_any_accepts_either_active_secret_test() {
  let token =
    auth.mint_token(
      "fluid",
      "doc-1",
      ["doc:read"],
      "user-1",
      "secret-1",
      100,
      3600,
    )
  // Signed with secret1, but secret1 is tried second here — order in the list
  // must not matter, only membership.
  let assert Ok(claims) =
    auth.verify_any(token, ["secret-2", "secret-1"], "fluid", "doc-1", 101)
  claims.tenant_id |> should.equal("fluid")

  let token2 =
    auth.mint_token(
      "fluid",
      "doc-1",
      ["doc:read"],
      "user-1",
      "secret-2",
      100,
      3600,
    )
  let assert Ok(_) =
    auth.verify_any(token2, ["secret-1", "secret-2"], "fluid", "doc-1", 101)
}

pub fn verify_any_rejects_when_no_secret_matches_test() {
  let token =
    auth.mint_token(
      "fluid",
      "doc-1",
      ["doc:read"],
      "user-1",
      "secret-1",
      100,
      3600,
    )
  auth.verify_any(token, ["secret-2", "secret-3"], "fluid", "doc-1", 101)
  |> should.equal(Error(auth.BadSignature))
  auth.verify_any(token, [], "fluid", "doc-1", 101)
  |> should.equal(Error(auth.BadSignature))
}

/// A token honestly minted for one tenant's secret does not verify against a
/// different tenant's secrets, even when both are otherwise well-formed and
/// registered — the cross-tenant isolation the admin API's per-tenant secrets
/// depend on.
pub fn verify_any_rejects_cross_tenant_secret_test() {
  let tenant_a_token =
    auth.mint_token(
      "tenant-a",
      "doc-1",
      ["doc:read"],
      "user-1",
      "tenant-a-secret",
      100,
      3600,
    )
  auth.verify_any(
    tenant_a_token,
    ["tenant-b-secret-1", "tenant-b-secret-2"],
    "tenant-b",
    "doc-1",
    101,
  )
  |> should.equal(Error(auth.BadSignature))
}

pub fn verify_write_authorization_any_accepts_either_active_secret_test() {
  let token =
    auth.mint_token(
      "fluid",
      "doc-1",
      ["doc:read", "doc:write"],
      "user-1",
      "secret-2",
      100,
      3600,
    )
  let assert Ok(_) =
    auth.verify_write_authorization_any(
      "Bearer " <> token,
      ["secret-1", "secret-2"],
      "fluid",
      "doc-1",
      101,
    )
  auth.verify_write_authorization_any(
    "Bearer " <> token,
    ["secret-1", "secret-3"],
    "fluid",
    "doc-1",
    101,
  )
  |> should.equal(Error(auth.BadSignature))
}

pub fn verify_tenant_write_authorization_any_accepts_either_active_secret_test() {
  let token =
    auth.mint_token(
      "fluid",
      "doc-1",
      ["doc:read", "doc:write"],
      "user-1",
      "secret-2",
      100,
      3600,
    )
  let assert Ok(_) =
    auth.verify_tenant_write_authorization_any(
      "Bearer " <> token,
      ["secret-1", "secret-2"],
      "fluid",
      101,
    )
}

pub fn verify_storage_read_and_write_authorization_any_accept_either_secret_test() {
  let token =
    auth.mint_token(
      "fluid",
      "doc-1",
      ["doc:read", "summary:write"],
      "user-1",
      "secret-2",
      100,
      3600,
    )
  let assert Ok(_) =
    auth.verify_storage_read_authorization_any(
      "Bearer " <> token,
      ["secret-1", "secret-2"],
      "fluid",
      101,
    )
  let assert Ok(_) =
    auth.verify_storage_write_authorization_any(
      "Bearer " <> token,
      ["secret-1", "secret-2"],
      "fluid",
      101,
    )
}
