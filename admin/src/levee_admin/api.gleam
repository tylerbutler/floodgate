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
  effect.from(fn(dispatch) {
    let body_string = json.to_string(body)

    let req =
      request.new()
      |> request.set_method(http.Post)
      |> request.set_host("")
      |> request.set_path(url)
      |> request.set_body(body_string)
      |> request.set_header("content-type", "application/json")

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
    let req =
      request.new()
      |> request.set_method(http.Get)
      |> request.set_host("")
      |> request.set_path(url)

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
