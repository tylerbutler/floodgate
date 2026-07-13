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
