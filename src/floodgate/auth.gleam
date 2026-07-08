//// JWT verification for Fluid connect_document. HS256 signature verify
//// (gleam_crypto) + claim parsing into spillway TokenClaims, then spillway
//// validates tenant/document/expiry. Analogue of levee's tenant token auth.

import gleam/bit_array
import gleam/crypto
import gleam/dict
import gleam/dynamic/decode
import gleam/json
import gleam/option.{None}
import gleam/result
import gleam/string
import spillway/jwt
import spillway/types.{type TokenClaims, TokenClaims, User}

pub type AuthError {
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

fn verify_signature(
  token: String,
  secret: String,
) -> Result(TokenClaims, AuthError) {
  case string.split(token, ".") {
    [h, p, sig] -> {
      let signed = bit_array.from_string(h <> "." <> p)
      let expected =
        crypto.hmac(signed, crypto.Sha256, bit_array.from_string(secret))
      case bit_array.base64_url_decode(sig) {
        Ok(actual) if actual == expected -> parse_claims(p)
        _ -> Error(BadSignature)
      }
    }
    _ -> Error(BadFormat)
  }
}

fn parse_claims(payload: String) -> Result(TokenClaims, AuthError) {
  let dec = {
    use doc <- decode.field("documentId", decode.string)
    use tenant <- decode.field("tenantId", decode.string)
    use exp <- decode.field("exp", decode.int)
    use scopes <- decode.optional_field(
      "scopes",
      [],
      decode.list(decode.string),
    )
    decode.success(TokenClaims(
      doc,
      scopes,
      tenant,
      User("", dict.new()),
      0,
      exp,
      "1.0",
      None,
    ))
  }
  use bytes <- result.try(
    bit_array.base64_url_decode(payload) |> result.replace_error(BadFormat),
  )
  use text <- result.try(
    bit_array.to_string(bytes) |> result.replace_error(BadFormat),
  )
  json.parse(text, dec) |> result.replace_error(BadFormat)
}
