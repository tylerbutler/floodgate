//// HTTP API client for Levee backend.
////
//// Uses gleam_fetch for browser HTTP requests with Lustre effects.

import gleam/dynamic/decode.{type Decoder}
import gleam/fetch
import gleam/http
import gleam/http/request
import gleam/http/response.{type Response}
import gleam/javascript/promise
import gleam/json
import gleam/option.{type Option, None, Some}
import lustre/effect.{type Effect}

@external(javascript, "../levee_admin_ffi.mjs", "get_origin")
fn get_origin() -> String

/// Base URL for API requests
const api_base = "/api"

// ─────────────────────────────────────────────────────────────────────────────
// Types
// ─────────────────────────────────────────────────────────────────────────────

pub type User {
  User(id: String, email: String, display_name: String, created_at: Int)
}

pub type AuthResponse {
  AuthResponse(user: User, token: String)
}

pub type ApiError {
  NetworkError(String)
  DecodeError(String)
  ServerError(Int, String)
}

// ─────────────────────────────────────────────────────────────────────────────
// Decoders
// ─────────────────────────────────────────────────────────────────────────────

fn user_decoder() -> Decoder(User) {
  use id <- decode.field("id", decode.string)
  use email <- decode.field("email", decode.string)
  use display_name <- decode.field("display_name", decode.string)
  use created_at <- decode.field("created_at", decode.int)
  decode.success(User(id:, email:, display_name:, created_at:))
}

fn auth_response_decoder() -> Decoder(AuthResponse) {
  use user <- decode.field("user", user_decoder())
  use token <- decode.field("token", decode.string)
  decode.success(AuthResponse(user:, token:))
}

// ─────────────────────────────────────────────────────────────────────────────
// HTTP Helpers
// ─────────────────────────────────────────────────────────────────────────────

fn post_json(
  url: String,
  body: json.Json,
  decoder: Decoder(a),
  on_response: fn(Result(a, ApiError)) -> msg,
) -> Effect(msg) {
  post_json_with_token(url, body, None, decoder, on_response)
}

fn post_json_with_token(
  url: String,
  body: json.Json,
  token: Option(String),
  decoder: Decoder(a),
  on_response: fn(Result(a, ApiError)) -> msg,
) -> Effect(msg) {
  effect.from(fn(dispatch) {
    let body_string = json.to_string(body)

    let assert Ok(req) = request.to(get_origin() <> url)
    let req =
      req
      |> request.set_method(http.Post)
      |> request.set_body(body_string)
      |> request.set_header("content-type", "application/json")

    let req = case token {
      Some(t) -> request.set_header(req, "authorization", "Bearer " <> t)
      None -> req
    }

    fetch.send(req)
    |> promise.try_await(fetch.read_text_body)
    |> promise.map(fn(result) {
      let api_result = case result {
        Ok(resp) -> handle_response(resp, decoder)
        Error(_) -> Error(NetworkError("Request failed"))
      }
      dispatch(on_response(api_result))
    })

    Nil
  })
}

fn put_json(
  url: String,
  body: json.Json,
  token: Option(String),
  decoder: Decoder(a),
  on_response: fn(Result(a, ApiError)) -> msg,
) -> Effect(msg) {
  effect.from(fn(dispatch) {
    let body_string = json.to_string(body)

    let assert Ok(req) = request.to(get_origin() <> url)
    let req =
      req
      |> request.set_method(http.Put)
      |> request.set_body(body_string)
      |> request.set_header("content-type", "application/json")

    let req = case token {
      Some(t) -> request.set_header(req, "authorization", "Bearer " <> t)
      None -> req
    }

    fetch.send(req)
    |> promise.try_await(fetch.read_text_body)
    |> promise.map(fn(result) {
      let api_result = case result {
        Ok(resp) -> handle_response(resp, decoder)
        Error(_) -> Error(NetworkError("Request failed"))
      }
      dispatch(on_response(api_result))
    })

    Nil
  })
}

fn delete_json(
  url: String,
  token: Option(String),
  decoder: Decoder(a),
  on_response: fn(Result(a, ApiError)) -> msg,
) -> Effect(msg) {
  effect.from(fn(dispatch) {
    let assert Ok(req) = request.to(get_origin() <> url)
    let req = request.set_method(req, http.Delete)

    let req = case token {
      Some(t) -> request.set_header(req, "authorization", "Bearer " <> t)
      None -> req
    }

    fetch.send(req)
    |> promise.try_await(fetch.read_text_body)
    |> promise.map(fn(result) {
      let api_result = case result {
        Ok(resp) -> handle_response(resp, decoder)
        Error(_) -> Error(NetworkError("Request failed"))
      }
      dispatch(on_response(api_result))
    })

    Nil
  })
}

fn get_json(
  url: String,
  token: Option(String),
  decoder: Decoder(a),
  on_response: fn(Result(a, ApiError)) -> msg,
) -> Effect(msg) {
  effect.from(fn(dispatch) {
    let assert Ok(req) = request.to(get_origin() <> url)

    let req = case token {
      Some(t) -> request.set_header(req, "authorization", "Bearer " <> t)
      None -> req
    }

    fetch.send(req)
    |> promise.try_await(fetch.read_text_body)
    |> promise.map(fn(result) {
      let api_result = case result {
        Ok(resp) -> handle_response(resp, decoder)
        Error(_) -> Error(NetworkError("Request failed"))
      }
      dispatch(on_response(api_result))
    })

    Nil
  })
}

fn handle_response(
  resp: Response(String),
  decoder: Decoder(a),
) -> Result(a, ApiError) {
  case resp.status >= 200 && resp.status < 300 {
    True -> {
      case json.parse(resp.body, decoder) {
        Ok(data) -> Ok(data)
        Error(_) -> Error(DecodeError("Failed to parse response"))
      }
    }
    False -> Error(ServerError(resp.status, resp.body))
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Auth API
// ─────────────────────────────────────────────────────────────────────────────

/// Register a new user
pub fn register(
  email: String,
  password: String,
  display_name: String,
  on_response: fn(Result(AuthResponse, ApiError)) -> msg,
) -> Effect(msg) {
  let body =
    json.object([
      #("email", json.string(email)),
      #("password", json.string(password)),
      #("display_name", json.string(display_name)),
    ])

  post_json(
    api_base <> "/auth/register",
    body,
    auth_response_decoder(),
    on_response,
  )
}

/// Login with email and password
pub fn login(
  email: String,
  password: String,
  on_response: fn(Result(AuthResponse, ApiError)) -> msg,
) -> Effect(msg) {
  let body =
    json.object([
      #("email", json.string(email)),
      #("password", json.string(password)),
    ])

  post_json(
    api_base <> "/auth/login",
    body,
    auth_response_decoder(),
    on_response,
  )
}

/// Get current user
pub fn get_me(
  token: String,
  on_response: fn(Result(User, ApiError)) -> msg,
) -> Effect(msg) {
  let user_wrapper_decoder = {
    use user <- decode.field("user", user_decoder())
    decode.success(user)
  }

  get_json(
    api_base <> "/auth/me",
    Some(token),
    user_wrapper_decoder,
    on_response,
  )
}

// ─────────────────────────────────────────────────────────────────────────────
// Tenant API
// ─────────────────────────────────────────────────────────────────────────────

pub type Tenant {
  Tenant(id: String)
}

pub type TenantList {
  TenantList(tenants: List(Tenant))
}

pub type TenantResponse {
  TenantResponse(tenant: Tenant, message: String)
}

pub type DeleteResponse {
  DeleteResponse(message: String)
}

fn tenant_decoder() -> Decoder(Tenant) {
  use id <- decode.field("id", decode.string)
  decode.success(Tenant(id:))
}

fn tenant_list_decoder() -> Decoder(TenantList) {
  use tenants <- decode.field("tenants", decode.list(tenant_decoder()))
  decode.success(TenantList(tenants:))
}

fn tenant_response_decoder() -> Decoder(TenantResponse) {
  use tenant <- decode.field("tenant", tenant_decoder())
  use message <- decode.field("message", decode.string)
  decode.success(TenantResponse(tenant:, message:))
}

fn delete_response_decoder() -> Decoder(DeleteResponse) {
  use message <- decode.field("message", decode.string)
  decode.success(DeleteResponse(message:))
}

/// List all tenants
pub fn list_tenants(
  token: String,
  on_response: fn(Result(TenantList, ApiError)) -> msg,
) -> Effect(msg) {
  get_json(
    api_base <> "/tenants",
    Some(token),
    tenant_list_decoder(),
    on_response,
  )
}

/// Get a single tenant
pub fn get_tenant(
  token: String,
  tenant_id: String,
  on_response: fn(Result(Tenant, ApiError)) -> msg,
) -> Effect(msg) {
  let tenant_wrapper_decoder = {
    use tenant <- decode.field("tenant", tenant_decoder())
    decode.success(tenant)
  }

  get_json(
    api_base <> "/tenants/" <> tenant_id,
    Some(token),
    tenant_wrapper_decoder,
    on_response,
  )
}

/// Create a new tenant
pub fn create_tenant(
  token: String,
  id: String,
  secret: String,
  on_response: fn(Result(TenantResponse, ApiError)) -> msg,
) -> Effect(msg) {
  let body =
    json.object([
      #("id", json.string(id)),
      #("secret", json.string(secret)),
    ])

  post_json_with_token(
    api_base <> "/tenants",
    body,
    Some(token),
    tenant_response_decoder(),
    on_response,
  )
}

/// Update a tenant's secret
pub fn update_tenant(
  token: String,
  tenant_id: String,
  secret: String,
  on_response: fn(Result(TenantResponse, ApiError)) -> msg,
) -> Effect(msg) {
  let body = json.object([#("secret", json.string(secret))])

  put_json(
    api_base <> "/tenants/" <> tenant_id,
    body,
    Some(token),
    tenant_response_decoder(),
    on_response,
  )
}

/// Delete a tenant
pub fn delete_tenant(
  token: String,
  tenant_id: String,
  on_response: fn(Result(DeleteResponse, ApiError)) -> msg,
) -> Effect(msg) {
  delete_json(
    api_base <> "/tenants/" <> tenant_id,
    Some(token),
    delete_response_decoder(),
    on_response,
  )
}
