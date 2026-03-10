//// HTTP API client for Levee backend.
////
//// Uses gleam_fetch for browser HTTP requests with Lustre effects.

import gleam/dynamic/decode.{type Decoder}
import gleam/fetch
import gleam/http
import gleam/http/request
import gleam/http/response.{type Response}
import gleam/int
import gleam/javascript/promise
import gleam/json
import gleam/option.{type Option, None, Some}
import lustre/effect.{type Effect}

@external(javascript, "../levee_admin_ffi.mjs", "get_origin")
pub fn get_origin() -> String

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
  Tenant(id: String, name: String)
}

pub type TenantWithSecrets {
  TenantWithSecrets(id: String, name: String, secret1: String, secret2: String)
}

pub type TenantList {
  TenantList(tenants: List(Tenant))
}

pub type RegenerateResponse {
  RegenerateResponse(secret: String)
}

pub type DeleteResponse {
  DeleteResponse(message: String)
}

fn tenant_decoder() -> Decoder(Tenant) {
  use id <- decode.field("id", decode.string)
  use name <- decode.field("name", decode.string)
  decode.success(Tenant(id:, name:))
}

fn tenant_with_secrets_decoder() -> Decoder(TenantWithSecrets) {
  use id <- decode.field("id", decode.string)
  use name <- decode.field("name", decode.string)
  use secret1 <- decode.field("secret1", decode.string)
  use secret2 <- decode.field("secret2", decode.string)
  decode.success(TenantWithSecrets(id:, name:, secret1:, secret2:))
}

fn tenant_list_decoder() -> Decoder(TenantList) {
  use tenants <- decode.field("tenants", decode.list(tenant_decoder()))
  decode.success(TenantList(tenants:))
}

fn create_tenant_response_decoder() -> Decoder(TenantWithSecrets) {
  use tenant <- decode.field("tenant", tenant_with_secrets_decoder())
  decode.success(tenant)
}

fn regenerate_response_decoder() -> Decoder(RegenerateResponse) {
  use secret <- decode.field("secret", decode.string)
  decode.success(RegenerateResponse(secret:))
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

/// Get a single tenant (no secrets)
pub fn get_tenant(
  token: String,
  tenant_id: String,
  on_response: fn(Result(TenantWithSecrets, ApiError)) -> msg,
) -> Effect(msg) {
  get_json(
    api_base <> "/tenants/" <> tenant_id,
    Some(token),
    create_tenant_response_decoder(),
    on_response,
  )
}

/// Create a new tenant (returns secrets)
pub fn create_tenant(
  token: String,
  name: String,
  on_response: fn(Result(TenantWithSecrets, ApiError)) -> msg,
) -> Effect(msg) {
  let body = json.object([#("name", json.string(name))])

  post_json_with_token(
    api_base <> "/tenants",
    body,
    Some(token),
    create_tenant_response_decoder(),
    on_response,
  )
}

/// Regenerate a specific secret slot (1 or 2)
pub fn regenerate_secret(
  token: String,
  tenant_id: String,
  slot: Int,
  on_response: fn(Result(RegenerateResponse, ApiError)) -> msg,
) -> Effect(msg) {
  let url =
    api_base <> "/tenants/" <> tenant_id <> "/secrets/" <> int.to_string(slot)

  post_json_with_token(
    url,
    json.object([]),
    Some(token),
    regenerate_response_decoder(),
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

// ─────────────────────────────────────────────────────────────────────────────
// Document Admin API
// ─────────────────────────────────────────────────────────────────────────────

pub type DocumentItem {
  DocumentItem(
    id: String,
    tenant_id: String,
    sequence_number: Int,
    session_alive: Bool,
  )
}

pub type DocumentListResponse {
  DocumentListResponse(documents: List(DocumentItem))
}

pub type SessionInfo {
  SessionInfo(
    current_sn: Int,
    current_msn: Int,
    client_count: Int,
    client_ids: List(String),
    history_size: Int,
  )
}

pub type DocumentDetailResponse {
  DocumentDetailResponse(document: DocumentItem, session: Option(SessionInfo))
}

pub type DeltaItem {
  DeltaItem(
    sequence_number: Int,
    client_id: Option(String),
    type_: String,
    reference_sequence_number: Int,
    minimum_sequence_number: Int,
    timestamp: Int,
    contents: String,
  )
}

pub type DeltaListResponse {
  DeltaListResponse(deltas: List(DeltaItem))
}

pub type SummaryItem {
  SummaryItem(
    handle: String,
    sequence_number: Int,
    tree_sha: Option(String),
    commit_sha: Option(String),
    parent_handle: Option(String),
  )
}

pub type SummaryListResponse {
  SummaryListResponse(summaries: List(SummaryItem))
}

pub type RefItem {
  RefItem(ref: String, sha: String)
}

pub type RefListResponse {
  RefListResponse(refs: List(RefItem))
}

pub type GitBlob {
  GitBlob(sha: String, size: Int, content: String)
}

pub type GitBlobResponse {
  GitBlobResponse(blob: GitBlob)
}

pub type GitTreeEntry {
  GitTreeEntry(path: String, mode: String, sha: String, entry_type: String)
}

pub type GitTree {
  GitTree(sha: String, tree: List(GitTreeEntry))
}

pub type GitTreeResponse {
  GitTreeResponse(tree: GitTree)
}

pub type GitCommit {
  GitCommit(
    sha: String,
    tree: String,
    parents: List(String),
    message: Option(String),
  )
}

pub type GitCommitResponse {
  GitCommitResponse(commit: GitCommit)
}

// Document decoders

fn document_item_decoder() -> Decoder(DocumentItem) {
  use id <- decode.field("id", decode.string)
  use tenant_id <- decode.field("tenant_id", decode.string)
  use sequence_number <- decode.field("sequence_number", decode.int)
  use session_alive <- decode.field("session_alive", decode.bool)
  decode.success(DocumentItem(id:, tenant_id:, sequence_number:, session_alive:))
}

fn document_list_response_decoder() -> Decoder(DocumentListResponse) {
  use documents <- decode.field(
    "documents",
    decode.list(document_item_decoder()),
  )
  decode.success(DocumentListResponse(documents:))
}

fn session_info_decoder() -> Decoder(SessionInfo) {
  use current_sn <- decode.field("current_sn", decode.int)
  use current_msn <- decode.field("current_msn", decode.int)
  use client_count <- decode.field("client_count", decode.int)
  use client_ids <- decode.field("client_ids", decode.list(decode.string))
  use history_size <- decode.field("history_size", decode.int)
  decode.success(SessionInfo(
    current_sn:,
    current_msn:,
    client_count:,
    client_ids:,
    history_size:,
  ))
}

fn document_detail_response_decoder() -> Decoder(DocumentDetailResponse) {
  use document <- decode.field("document", document_item_decoder())
  use session <- decode.field(
    "session",
    decode.optional(session_info_decoder()),
  )
  decode.success(DocumentDetailResponse(document:, session:))
}

fn delta_item_decoder() -> Decoder(DeltaItem) {
  use sequence_number <- decode.field("sequence_number", decode.int)
  use client_id <- decode.field("client_id", decode.optional(decode.string))
  use type_ <- decode.field("type", decode.string)
  use reference_sequence_number <- decode.field(
    "reference_sequence_number",
    decode.int,
  )
  use minimum_sequence_number <- decode.field(
    "minimum_sequence_number",
    decode.int,
  )
  use timestamp <- decode.field("timestamp", decode.int)
  use contents <- decode.field(
    "contents",
    decode.one_of(decode.string, [decode.success("")]),
  )
  decode.success(DeltaItem(
    sequence_number:,
    client_id:,
    type_:,
    reference_sequence_number:,
    minimum_sequence_number:,
    timestamp:,
    contents:,
  ))
}

fn delta_list_response_decoder() -> Decoder(DeltaListResponse) {
  use deltas <- decode.field("deltas", decode.list(delta_item_decoder()))
  decode.success(DeltaListResponse(deltas:))
}

fn summary_item_decoder() -> Decoder(SummaryItem) {
  use handle <- decode.field("handle", decode.string)
  use sequence_number <- decode.field("sequence_number", decode.int)
  use tree_sha <- decode.field("tree_sha", decode.optional(decode.string))
  use commit_sha <- decode.field("commit_sha", decode.optional(decode.string))
  use parent_handle <- decode.field(
    "parent_handle",
    decode.optional(decode.string),
  )
  decode.success(SummaryItem(
    handle:,
    sequence_number:,
    tree_sha:,
    commit_sha:,
    parent_handle:,
  ))
}

fn summary_list_response_decoder() -> Decoder(SummaryListResponse) {
  use summaries <- decode.field(
    "summaries",
    decode.list(summary_item_decoder()),
  )
  decode.success(SummaryListResponse(summaries:))
}

fn ref_item_decoder() -> Decoder(RefItem) {
  use ref <- decode.field("ref", decode.string)
  use sha <- decode.field("sha", decode.string)
  decode.success(RefItem(ref:, sha:))
}

fn ref_list_response_decoder() -> Decoder(RefListResponse) {
  use refs <- decode.field("refs", decode.list(ref_item_decoder()))
  decode.success(RefListResponse(refs:))
}

fn git_blob_decoder() -> Decoder(GitBlob) {
  use sha <- decode.field("sha", decode.string)
  use size <- decode.field("size", decode.int)
  use content <- decode.field("content", decode.string)
  decode.success(GitBlob(sha:, size:, content:))
}

fn git_blob_response_decoder() -> Decoder(GitBlobResponse) {
  use blob <- decode.field("blob", git_blob_decoder())
  decode.success(GitBlobResponse(blob:))
}

fn git_tree_entry_decoder() -> Decoder(GitTreeEntry) {
  use path <- decode.field("path", decode.string)
  use mode <- decode.field("mode", decode.string)
  use sha <- decode.field("sha", decode.string)
  use entry_type <- decode.field("type", decode.string)
  decode.success(GitTreeEntry(path:, mode:, sha:, entry_type:))
}

fn git_tree_decoder() -> Decoder(GitTree) {
  use sha <- decode.field("sha", decode.string)
  use tree <- decode.field("tree", decode.list(git_tree_entry_decoder()))
  decode.success(GitTree(sha:, tree:))
}

fn git_tree_response_decoder() -> Decoder(GitTreeResponse) {
  use tree <- decode.field("tree", git_tree_decoder())
  decode.success(GitTreeResponse(tree:))
}

fn git_commit_decoder() -> Decoder(GitCommit) {
  use sha <- decode.field("sha", decode.string)
  use tree <- decode.field("tree", decode.string)
  use parents <- decode.field("parents", decode.list(decode.string))
  use message <- decode.field("message", decode.optional(decode.string))
  decode.success(GitCommit(sha:, tree:, parents:, message:))
}

fn git_commit_response_decoder() -> Decoder(GitCommitResponse) {
  use commit <- decode.field("commit", git_commit_decoder())
  decode.success(GitCommitResponse(commit:))
}

// Document API functions

pub fn list_documents(
  token: String,
  tenant_id: String,
  on_response: fn(Result(DocumentListResponse, ApiError)) -> msg,
) -> Effect(msg) {
  get_json(
    api_base <> "/tenants/" <> tenant_id <> "/documents",
    Some(token),
    document_list_response_decoder(),
    on_response,
  )
}

pub fn get_document(
  token: String,
  tenant_id: String,
  document_id: String,
  on_response: fn(Result(DocumentDetailResponse, ApiError)) -> msg,
) -> Effect(msg) {
  get_json(
    api_base <> "/tenants/" <> tenant_id <> "/documents/" <> document_id,
    Some(token),
    document_detail_response_decoder(),
    on_response,
  )
}

pub fn get_document_deltas(
  token: String,
  tenant_id: String,
  document_id: String,
  from: Int,
  limit: Int,
  on_response: fn(Result(DeltaListResponse, ApiError)) -> msg,
) -> Effect(msg) {
  get_json(
    api_base
      <> "/tenants/"
      <> tenant_id
      <> "/documents/"
      <> document_id
      <> "/deltas?from="
      <> int.to_string(from)
      <> "&limit="
      <> int.to_string(limit),
    Some(token),
    delta_list_response_decoder(),
    on_response,
  )
}

pub fn get_document_summaries(
  token: String,
  tenant_id: String,
  document_id: String,
  on_response: fn(Result(SummaryListResponse, ApiError)) -> msg,
) -> Effect(msg) {
  get_json(
    api_base
      <> "/tenants/"
      <> tenant_id
      <> "/documents/"
      <> document_id
      <> "/summaries",
    Some(token),
    summary_list_response_decoder(),
    on_response,
  )
}

pub fn get_document_refs(
  token: String,
  tenant_id: String,
  on_response: fn(Result(RefListResponse, ApiError)) -> msg,
) -> Effect(msg) {
  get_json(
    api_base <> "/tenants/" <> tenant_id <> "/refs",
    Some(token),
    ref_list_response_decoder(),
    on_response,
  )
}

pub fn get_admin_blob(
  token: String,
  tenant_id: String,
  sha: String,
  on_response: fn(Result(GitBlobResponse, ApiError)) -> msg,
) -> Effect(msg) {
  get_json(
    api_base <> "/tenants/" <> tenant_id <> "/git/blobs/" <> sha,
    Some(token),
    git_blob_response_decoder(),
    on_response,
  )
}

pub fn get_admin_tree(
  token: String,
  tenant_id: String,
  sha: String,
  recursive: Bool,
  on_response: fn(Result(GitTreeResponse, ApiError)) -> msg,
) -> Effect(msg) {
  let url =
    api_base
    <> "/tenants/"
    <> tenant_id
    <> "/git/trees/"
    <> sha
    <> case recursive {
      True -> "?recursive=1"
      False -> ""
    }
  get_json(url, Some(token), git_tree_response_decoder(), on_response)
}

pub fn get_admin_commit(
  token: String,
  tenant_id: String,
  sha: String,
  on_response: fn(Result(GitCommitResponse, ApiError)) -> msg,
) -> Effect(msg) {
  get_json(
    api_base <> "/tenants/" <> tenant_id <> "/git/commits/" <> sha,
    Some(token),
    git_commit_response_decoder(),
    on_response,
  )
}
