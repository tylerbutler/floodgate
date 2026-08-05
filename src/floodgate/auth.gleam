//// JWT verification for Fluid connect_document. HS256 signature verify
//// (gleam_crypto) + claim parsing into spillway TokenClaims, then spillway
//// validates tenant/document/expiry. Analogue of levee's tenant token auth.

import gleam/bit_array
import gleam/crypto
import gleam/dict
import gleam/dynamic
import gleam/dynamic/decode
import gleam/json
import gleam/option.{None}
import gleam/result
import gleam/string
import signet/jwt
import signet/types.{type TokenClaims, TokenClaims, User, scopes_from_strings}

pub type AuthError {
  /// No `Authorization` header at all, as distinct from a malformed one —
  /// levee reports these differently, so floodgate has to as well.
  MissingAuthorization
  BadFormat
  BadSignature
  BadClaims(jwt.JwtValidationError)
}

/// Verify HS256 token + validate connection claims against the topic ids.
pub fn verify(
  token: String,
  secret: String,
  tenant: String,
  doc: String,
  now: Int,
) -> Result(TokenClaims, AuthError) {
  use claims <- result.try(verify_signature(token, secret))
  case jwt.validate_connection_claims(claims, tenant, doc, now) {
    Ok(_) -> Ok(claims)
    Error(e) -> Error(BadClaims(e))
  }
}

/// Verify a REST write token from either Routerlicious's `Basic` scheme or the
/// conventional `Bearer` scheme used by direct API callers.
pub fn verify_write_authorization(
  authorization: String,
  secret: String,
  tenant: String,
  doc: String,
  now: Int,
) -> Result(TokenClaims, AuthError) {
  use token <- result.try(extract_token(authorization))
  use claims <- result.try(verify_signature(token, secret))
  use _ <- result.try(
    jwt.validate_write_access(claims, tenant, doc, now)
    |> result.map_error(BadClaims),
  )
  Ok(claims)
}

/// Verify a REST read token from either Routerlicious's `Basic` scheme or the
/// conventional `Bearer` scheme used by direct API callers.
pub fn verify_read_authorization(
  authorization: String,
  secret: String,
  tenant: String,
  doc: String,
  now: Int,
) -> Result(TokenClaims, AuthError) {
  use token <- result.try(extract_token(authorization))
  use claims <- result.try(verify_signature(token, secret))
  use _ <- result.try(
    jwt.validate_read_access(claims, tenant, doc, now)
    |> result.map_error(BadClaims),
  )
  Ok(claims)
}

/// Verify write access for a route that carries no document id in its path
/// (`POST /documents/:tenant`, where the id is chosen from the body or
/// generated). Levee's auth plug skips document validation entirely when the
/// route has no `:id` param; validating against the token's own document id is
/// the equivalent, and keeps a document-scoped token working for the create
/// call the driver makes.
pub fn verify_tenant_write_authorization(
  authorization: String,
  secret: String,
  tenant: String,
  now: Int,
) -> Result(TokenClaims, AuthError) {
  use claims <- result.try(authorization_claims(authorization, secret))
  use _ <- result.try(
    jwt.validate_write_access(claims, tenant, claims.document_id, now)
    |> result.map_error(BadClaims),
  )
  Ok(claims)
}

/// Verify read access for tenant-scoped Historian routes, using the document
/// carried by the storage token itself.
pub fn verify_storage_read_authorization(
  authorization: String,
  secret: String,
  tenant: String,
  now: Int,
) -> Result(TokenClaims, AuthError) {
  use claims <- result.try(authorization_claims(authorization, secret))
  use _ <- result.try(
    jwt.validate_read_access(claims, tenant, claims.document_id, now)
    |> result.map_error(BadClaims),
  )
  Ok(claims)
}

/// Verify summary-write access for tenant-scoped Historian routes.
pub fn verify_storage_write_authorization(
  authorization: String,
  secret: String,
  tenant: String,
  now: Int,
) -> Result(TokenClaims, AuthError) {
  use claims <- result.try(authorization_claims(authorization, secret))
  use _ <- result.try(
    jwt.validate_summary_access(claims, tenant, claims.document_id, now)
    |> result.map_error(BadClaims),
  )
  Ok(claims)
}

pub fn extract_token(authorization: String) -> Result(String, AuthError) {
  case string.split(authorization, " ") {
    ["Basic", token] if token != "" -> extract_basic_token(token)
    ["Bearer", token] if token != "" -> Ok(token)
    _ -> Error(BadFormat)
  }
}

fn extract_basic_token(token: String) -> Result(String, AuthError) {
  case string.contains(token, ".") {
    True -> Ok(token)
    False -> {
      use credentials <- result.try(
        bit_array.base64_decode(token) |> result.replace_error(BadFormat),
      )
      use credentials <- result.try(
        bit_array.to_string(credentials) |> result.replace_error(BadFormat),
      )
      case string.split(credentials, ":") {
        [_, jwt] if jwt != "" -> Ok(jwt)
        _ -> Error(BadFormat)
      }
    }
  }
}

fn authorization_claims(
  authorization: String,
  secret: String,
) -> Result(TokenClaims, AuthError) {
  use token <- result.try(extract_token(authorization))
  verify_signature(token, secret)
}

/// Verify the separate bearer credential that enables integration token minting.
pub fn verify_token_mint_authorization(
  authorization: String,
  expected_secret: String,
) -> Result(Nil, AuthError) {
  case string.split(authorization, " ") {
    ["Bearer", token] if token != "" && expected_secret != "" ->
      case
        secure_compare(
          bit_array.from_string(token),
          bit_array.from_string(expected_secret),
        )
      {
        True -> Ok(Nil)
        False -> Error(BadSignature)
      }
    _ -> Error(BadFormat)
  }
}

/// Mint a strict HS256 document token for the configured standalone tenant.
pub fn mint_token(
  tenant: String,
  document_id: String,
  scopes: List(String),
  user_id: String,
  secret: String,
  now: Int,
  expires_in: Int,
) -> String {
  let header =
    json.object([
      #("alg", json.string("HS256")),
      #("typ", json.string("JWT")),
    ])
    |> json.to_string
    |> bit_array.from_string
    |> bit_array.base64_url_encode(False)
  let payload =
    json.object([
      #("documentId", json.string(document_id)),
      #("tenantId", json.string(tenant)),
      #("scopes", json.array(scopes, json.string)),
      #("user", json.object([#("id", json.string(user_id))])),
      #("ver", json.string("1.0")),
      #("iat", json.int(now)),
      #("exp", json.int(now + expires_in)),
      #(
        "jti",
        crypto.strong_random_bytes(16)
          |> bit_array.base16_encode
          |> string.lowercase
          |> json.string,
      ),
    ])
    |> json.to_string
    |> bit_array.from_string
    |> bit_array.base64_url_encode(False)
  let signed = header <> "." <> payload
  let signature =
    crypto.hmac(
      bit_array.from_string(signed),
      crypto.Sha256,
      bit_array.from_string(secret),
    )
    |> bit_array.base64_url_encode(False)
  signed <> "." <> signature
}

fn verify_signature(
  token: String,
  secret: String,
) -> Result(TokenClaims, AuthError) {
  case secret, string.split(token, ".") {
    "", _ -> Error(BadSignature)
    _, [h, p, sig] -> {
      use _ <- result.try(verify_header(h))
      let signed = bit_array.from_string(h <> "." <> p)
      let expected =
        crypto.hmac(signed, crypto.Sha256, bit_array.from_string(secret))
      case bit_array.base64_url_decode(sig) {
        Ok(actual) ->
          case secure_compare(actual, expected) {
            True -> parse_claims(p)
            False -> Error(BadSignature)
          }
        _ -> Error(BadSignature)
      }
    }
    _, _ -> Error(BadFormat)
  }
}

fn verify_header(header: String) -> Result(Nil, AuthError) {
  use bytes <- result.try(
    bit_array.base64_url_decode(header) |> result.replace_error(BadFormat),
  )
  use text <- result.try(
    bit_array.to_string(bytes) |> result.replace_error(BadFormat),
  )
  use algorithm <- result.try(
    json.parse(text, decode.field("alg", decode.string, decode.success))
    |> result.replace_error(BadFormat),
  )
  case algorithm {
    "HS256" -> Ok(Nil)
    _ -> Error(BadFormat)
  }
}

fn parse_claims(payload: String) -> Result(TokenClaims, AuthError) {
  let dec = {
    use doc <- decode.field("documentId", decode.string)
    use tenant <- decode.field("tenantId", decode.string)
    use exp <- decode.field("exp", decode.int)
    use scopes <- decode.field("scopes", decode.list(decode.string))
    use user <- decode.field("user", {
      use id <- decode.field("id", decode.string)
      use name <- decode.optional_field("name", id, decode.string)
      decode.success(User(id, dict.from_list([#("name", dynamic.string(name))])))
    })
    use issued_at <- decode.field("iat", decode.int)
    use version <- decode.field("ver", decode.string)
    use jti <- decode.optional_field(
      "jti",
      None,
      decode.optional(decode.string),
    )
    decode.success(TokenClaims(
      doc,
      scopes_from_strings(scopes),
      tenant,
      user,
      issued_at,
      exp,
      version,
      jti,
    ))
  }
  use bytes <- result.try(
    bit_array.base64_url_decode(payload) |> result.replace_error(BadFormat),
  )
  use text <- result.try(
    bit_array.to_string(bytes) |> result.replace_error(BadFormat),
  )
  use claims <- result.try(
    json.parse(text, dec) |> result.replace_error(BadFormat),
  )
  case claims.version == "1.0", claims.user.id != "" {
    True, True -> Ok(claims)
    _, _ -> Error(BadFormat)
  }
}

@external(erlang, "floodgate_ffi", "secure_compare")
fn secure_compare(left: BitArray, right: BitArray) -> Bool
