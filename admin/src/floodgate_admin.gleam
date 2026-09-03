//// Floodgate Admin - Tenant Management UI
////
//// A Lustre-based single-page application for managing Floodgate tenants,
//// users, and document access.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/uri.{type Uri}
import lustre
import lustre/attribute.{class}
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html.{div, h1, nav, p, text}
import lustre/event
import modem

@external(javascript, "./floodgate_admin_ffi.mjs", "get_query_param")
fn get_query_param(name: String) -> Option(String)

@external(javascript, "./floodgate_admin_ffi.mjs", "navigate_to")
fn do_navigate_to(url: String) -> Nil

@external(javascript, "./floodgate_admin_ffi.mjs", "get_current_path")
fn get_current_path() -> String

@external(javascript, "./floodgate_admin_ffi.mjs", "save_token")
fn save_token(token: String) -> Nil

@external(javascript, "./floodgate_admin_ffi.mjs", "load_token")
fn load_token() -> Option(String)

@external(javascript, "./floodgate_admin_ffi.mjs", "clear_token")
fn clear_token() -> Nil

@external(javascript, "./floodgate_admin_ffi.mjs", "set_document_title")
fn set_document_title(title: String) -> Nil

import floodgate_admin/api
import floodgate_admin/pages/dashboard
import floodgate_admin/pages/document_detail
import floodgate_admin/pages/document_list
import floodgate_admin/pages/login
import floodgate_admin/pages/register
import floodgate_admin/pages/tenant_detail
import floodgate_admin/pages/tenant_new
import floodgate_admin/pages/tenants
import floodgate_admin/router.{type Route}

// ─────────────────────────────────────────────────────────────────────────────
// Model
// ─────────────────────────────────────────────────────────────────────────────

pub type Model {
  Model(
    route: Route,
    user: Option(User),
    session_token: Option(String),
    password_auth: Bool,
    login: login.Model,
    register: register.Model,
    dashboard: dashboard.Model,
    tenants: tenants.Model,
    tenant_new: tenant_new.Model,
    tenant_detail: tenant_detail.Model,
    document_list: document_list.Model,
    document_detail: document_detail.Model,
    flash_message: Option(String),
    /// Route the operator was on when a protected call failed with 401/403, so
    /// re-authentication can return them there instead of always the dashboard.
    return_to: Option(Route),
  )
}

pub type User {
  User(id: String, email: String, display_name: String)
}

fn init(_flags) -> #(Model, Effect(Msg)) {
  // Restore a bearer token when present. Floodgate also uses an HttpOnly
  // session cookie, so without a token we probe `/api/auth/me` without an
  // Authorization header and let the browser send that cookie.
  let #(session_token, auth_effect) = case get_query_param("token") {
    Some(token) -> {
      save_token(token)
      #(Some(token), api.get_me(token, MeResponse))
    }
    None ->
      case load_token() {
        Some(token) -> #(Some(token), api.get_me(token, MeResponse))
        None -> #(None, api.get_me("", MeResponse))
      }
  }

  // Parse the initial route from the current URL path,
  // applying auth guards for protected routes
  let requested_route = case uri.parse(get_current_path()) {
    Ok(parsed_uri) -> router.parse(parsed_uri)
    Error(_) -> router.Login
  }
  let return_to = case is_protected_route(requested_route) {
    True -> Some(requested_route)
    False -> None
  }
  let initial_route = case session_token, is_protected_route(requested_route) {
    None, True -> router.Login
    _, _ -> requested_route
  }

  let model =
    Model(
      route: initial_route,
      user: None,
      session_token: session_token,
      password_auth: True,
      login: login.init(),
      register: register.init(),
      dashboard: dashboard.init(),
      tenants: tenants.init(),
      tenant_new: tenant_new.init(),
      tenant_detail: tenant_detail.init(""),
      document_list: document_list.init(""),
      document_detail: document_detail.init("", ""),
      flash_message: None,
      return_to: return_to,
    )

  #(
    model,
    effect.batch([
      modem.init(on_url_change),
      auth_effect,
      api.get_auth_config(AuthConfigResponse),
      title_effect(initial_route),
    ]),
  )
}

// ─────────────────────────────────────────────────────────────────────────────
// Messages
// ─────────────────────────────────────────────────────────────────────────────

pub type Msg {
  OnRouteChange(Route)
  LoginMsg(login.Msg)
  RegisterMsg(register.Msg)
  DashboardMsg(dashboard.Msg)
  TenantsMsg(tenants.Msg)
  TenantNewMsg(tenant_new.Msg)
  TenantDetailMsg(tenant_detail.Msg)
  DocumentListMsg(document_list.Msg)
  DocumentDetailMsg(document_detail.Msg)
  // Auth API responses
  LoginResponse(Result(api.AuthResponse, api.ApiError))
  RegisterResponse(Result(api.AuthResponse, api.ApiError))
  MeResponse(Result(api.User, api.ApiError))
  AuthConfigResponse(Result(api.AuthConfig, api.ApiError))
  LogoutResponse(Result(api.LogoutResponse, api.ApiError))
  // Tenant API responses
  TenantsResponse(Result(api.TenantList, api.ApiError))
  DashboardTenantsResponse(Result(api.TenantList, api.ApiError))
  CreateTenantResponse(Result(api.TenantWithSecrets, api.ApiError))
  GetTenantResponse(Result(api.TenantWithSecrets, api.ApiError))
  RegenerateSecretResponse(Int, Result(api.RegenerateResponse, api.ApiError))
  DeleteTenantResponse(Result(api.DeleteResponse, api.ApiError))
  // Tenant document count (for tenant detail page)
  TenantDocumentCountResponse(Result(api.DocumentListResponse, api.ApiError))
  // Document admin API responses
  DocumentListResponse(Result(api.DocumentListResponse, api.ApiError))
  DocumentDetailResponse(Result(api.DocumentDetailResponse, api.ApiError))
  DocumentDeltasResponse(Result(api.DeltaListResponse, api.ApiError))
  DocumentSummariesResponse(Result(api.SummaryListResponse, api.ApiError))
  DocumentRefsResponse(Result(api.RefListResponse, api.ApiError))
  GitBlobResponse(Result(api.GitBlobResponse, api.ApiError))
  GitTreeResponse(Result(api.GitTreeResponse, api.ApiError))
  GitCommitResponse(Result(api.GitCommitResponse, api.ApiError))
  DismissFlash
  Logout
}

fn on_url_change(uri: Uri) -> Msg {
  OnRouteChange(router.parse(uri))
}

// ─────────────────────────────────────────────────────────────────────────────
// Route helpers
// ─────────────────────────────────────────────────────────────────────────────

fn is_protected_route(route: Route) -> Bool {
  case route {
    router.Dashboard
    | router.Tenants
    | router.TenantNew
    | router.TenantDetail(_)
    | router.DocumentList(_)
    | router.DocumentDetail(_, _) -> True
    router.Login | router.Register | router.NotFound -> False
  }
}

/// Data to fetch when a protected route becomes active. Shared by URL changes
/// and post-authentication navigation so both paths load identically.
fn load_for_route(route: Route, token: String) -> Effect(Msg) {
  case route {
    router.Dashboard -> api.list_tenants(token, DashboardTenantsResponse)
    router.Tenants -> api.list_tenants(token, TenantsResponse)
    router.TenantDetail(id) ->
      effect.batch([
        api.get_tenant(token, id, GetTenantResponse),
        api.list_documents(token, id, TenantDocumentCountResponse),
      ])
    router.DocumentList(tid) ->
      api.list_documents(token, tid, DocumentListResponse)
    router.DocumentDetail(tid, did) ->
      effect.batch([
        api.get_document(token, tid, did, DocumentDetailResponse),
        api.get_document_deltas(
          token,
          tid,
          did,
          -1,
          document_detail.page_size,
          DocumentDeltasResponse,
        ),
        api.get_document_summaries(token, tid, did, DocumentSummariesResponse),
        api.get_document_refs(token, tid, DocumentRefsResponse),
      ])
    _ -> effect.none()
  }
}

/// Reset the page sub-model a route owns to its initial state on entry.
fn reset_page_for_route(model: Model, route: Route) -> Model {
  case route {
    router.Tenants -> Model(..model, route:, tenants: tenants.init())
    router.TenantNew -> Model(..model, route:, tenant_new: tenant_new.init())
    router.TenantDetail(id) ->
      Model(..model, route:, tenant_detail: tenant_detail.init(id))
    router.Dashboard ->
      Model(
        ..model,
        route:,
        dashboard: dashboard.start_loading(dashboard.init()),
      )
    router.DocumentList(tid) ->
      Model(..model, route:, document_list: document_list.init(tid))
    router.DocumentDetail(tid, did) ->
      Model(..model, route:, document_detail: document_detail.init(tid, did))
    _ -> Model(..model, route:)
  }
}

/// A per-route document title, so browser history and assistive technology get
/// a meaningful, distinct label for each SPA view.
fn page_title(route: Route) -> String {
  case route {
    router.Login -> "Sign in · Floodgate Admin"
    router.Register -> "Create account · Floodgate Admin"
    router.Dashboard -> "Dashboard · Floodgate Admin"
    router.Tenants -> "Tenants · Floodgate Admin"
    router.TenantNew -> "New tenant · Floodgate Admin"
    router.TenantDetail(id) -> "Tenant " <> id <> " · Floodgate Admin"
    router.DocumentList(_) -> "Documents · Floodgate Admin"
    router.DocumentDetail(_, did) -> "Document " <> did <> " · Floodgate Admin"
    router.NotFound -> "Not found · Floodgate Admin"
  }
}

fn title_effect(route: Route) -> Effect(Msg) {
  effect.from(fn(_dispatch) { set_document_title(page_title(route)) })
}

/// End the session locally and return to sign-in. Clears the bearer token,
/// records the current route so re-authentication can come back to it, and
/// shows a session-expired message instead of a Retry that would 401 again.
fn expire_session(model: Model) -> #(Model, Effect(Msg)) {
  clear_token()
  let return_to = case model.route {
    router.Login | router.Register -> model.return_to
    other -> Some(other)
  }
  let login_model =
    login.set_error(
      model.login,
      "Your session expired. Sign in again to continue.",
    )
  #(
    Model(
      ..model,
      user: None,
      session_token: None,
      route: router.Login,
      login: login_model,
      return_to: return_to,
    ),
    effect.batch([
      modem.push("/admin/login", None, None),
      title_effect(router.Login),
    ]),
  )
}

/// Route a failed protected call: expire the session on 401/403, otherwise run
/// the page-specific recovery so the operator keeps a useful, accurate message.
fn handle_error(
  model: Model,
  error: api.ApiError,
  recover: fn() -> #(Model, Effect(Msg)),
) -> #(Model, Effect(Msg)) {
  case api.is_session_expired(error) {
    True -> expire_session(model)
    False -> recover()
  }
}

/// Complete sign-in: adopt the session, then navigate to the intended return
/// route (or the dashboard) and load it through the shared route dispatch.
fn enter_session(
  model: Model,
  user: User,
  token: String,
) -> #(Model, Effect(Msg)) {
  let target = option.unwrap(model.return_to, router.Dashboard)
  let base =
    Model(
      ..model,
      user: Some(user),
      session_token: Some(token),
      login: login.init(),
      register: register.init(),
      return_to: None,
    )
  let model = reset_page_for_route(base, target)
  #(
    model,
    effect.batch([
      load_for_route(target, token),
      modem.push(router.to_path(target), None, None),
      title_effect(target),
    ]),
  )
}

// ─────────────────────────────────────────────────────────────────────────────
// Update
// ─────────────────────────────────────────────────────────────────────────────

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    OnRouteChange(route) -> {
      // Redirect to login if not authenticated and trying to access protected route
      let route = case model.session_token, model.password_auth, route {
        _, False, router.Register -> router.Login
        None, _, router.Dashboard -> router.Login
        None, _, router.Tenants -> router.Login
        None, _, router.TenantNew -> router.Login
        None, _, router.TenantDetail(_) -> router.Login
        None, _, router.DocumentList(_) -> router.Login
        None, _, router.DocumentDetail(_, _) -> router.Login
        _, _, r -> r
      }
      let route_changed = route != model.route
      let title = title_effect(route)

      case route_changed {
        False -> #(model, title)
        True -> {
          let load = case model.session_token {
            Some(token) -> load_for_route(route, token)
            None -> effect.none()
          }
          let model = reset_page_for_route(model, route)
          #(model, effect.batch([load, title]))
        }
      }
    }

    DismissFlash -> #(Model(..model, flash_message: None), effect.none())

    LoginMsg(login.GitHubLogin) -> {
      // Redirect to GitHub OAuth — full page navigation. Show progress first so
      // the click is acknowledged before the browser leaves the page.
      let login_model = login.start_github_redirect(model.login)
      #(
        Model(..model, login: login_model),
        effect.from(fn(_dispatch) { do_navigate_to("/auth/github") }),
      )
    }

    LoginMsg(login_msg) -> {
      let #(login_model, login_effect) = login.update(model.login, login_msg)
      let effect = effect.map(login_effect, LoginMsg)

      // Check if there's a pending submission
      case login.get_pending_submit(login_model) {
        Some(data) -> {
          // Start loading and make API call
          let login_model = login.start_loading(login_model)
          let api_effect = api.login(data.email, data.password, LoginResponse)
          #(Model(..model, login: login_model), api_effect)
        }
        None -> #(Model(..model, login: login_model), effect)
      }
    }

    RegisterMsg(register_msg) -> {
      let #(register_model, register_effect) =
        register.update(model.register, register_msg)
      let effect = effect.map(register_effect, RegisterMsg)

      // Check if there's a pending submission
      case register.get_pending_submit(register_model) {
        Some(data) -> {
          // Start loading and make API call
          let register_model = register.start_loading(register_model)
          let api_effect =
            api.register(
              data.email,
              data.password,
              data.display_name,
              RegisterResponse,
            )
          #(Model(..model, register: register_model), api_effect)
        }
        None -> #(Model(..model, register: register_model), effect)
      }
    }

    DashboardMsg(dashboard_msg) -> {
      let #(dashboard_model, dashboard_effect) =
        dashboard.update(model.dashboard, dashboard_msg)
      let effect = effect.map(dashboard_effect, DashboardMsg)
      #(Model(..model, dashboard: dashboard_model), effect)
    }

    TenantsMsg(tenants_msg) -> {
      let #(tenants_model, tenants_effect) =
        tenants.update(model.tenants, tenants_msg)
      let mapped_effect = effect.map(tenants_effect, TenantsMsg)

      case tenants_msg {
        tenants.Retry ->
          case model.session_token {
            Some(token) -> #(
              Model(..model, tenants: tenants_model),
              api.list_tenants(token, TenantsResponse),
            )
            None -> #(Model(..model, tenants: tenants_model), mapped_effect)
          }
        _ -> #(Model(..model, tenants: tenants_model), mapped_effect)
      }
    }

    TenantNewMsg(tenant_new_msg) -> {
      let #(tenant_new_model, tenant_new_effect) =
        tenant_new.update(model.tenant_new, tenant_new_msg)
      let mapped_effect = effect.map(tenant_new_effect, TenantNewMsg)

      case
        tenant_new.get_pending_submit(tenant_new_model),
        model.session_token
      {
        Some(name), Some(token) -> {
          let tenant_new_model = tenant_new.start_loading(tenant_new_model)
          let api_effect = api.create_tenant(token, name, CreateTenantResponse)
          #(Model(..model, tenant_new: tenant_new_model), api_effect)
        }
        _, _ -> #(Model(..model, tenant_new: tenant_new_model), mapped_effect)
      }
    }

    TenantDetailMsg(detail_msg) -> {
      let #(detail_model, detail_effect) =
        tenant_detail.update(model.tenant_detail, detail_msg)
      let mapped_effect = effect.map(detail_effect, TenantDetailMsg)

      case
        tenant_detail.get_pending_regenerate(detail_model),
        model.session_token
      {
        Some(slot), Some(token) -> {
          let detail_model =
            tenant_detail.start_regenerate_loading(detail_model, slot)
          let api_effect =
            api.regenerate_secret(
              token,
              detail_model.tenant_id,
              slot,
              fn(result) { RegenerateSecretResponse(slot, result) },
            )
          #(Model(..model, tenant_detail: detail_model), api_effect)
        }
        _, _ -> {
          case
            tenant_detail.get_pending_delete(detail_model),
            model.session_token
          {
            True, Some(token) -> {
              let detail_model =
                tenant_detail.start_delete_loading(detail_model)
              let api_effect =
                api.delete_tenant(
                  token,
                  detail_model.tenant_id,
                  DeleteTenantResponse,
                )
              #(Model(..model, tenant_detail: detail_model), api_effect)
            }
            _, _ -> #(
              Model(..model, tenant_detail: detail_model),
              mapped_effect,
            )
          }
        }
      }
    }

    LoginResponse(Ok(response)) -> {
      save_token(response.token)
      let user =
        User(
          id: response.user.id,
          email: response.user.email,
          display_name: response.user.display_name,
        )
      enter_session(model, user, response.token)
    }

    LoginResponse(Error(_error)) -> {
      let login_model =
        login.set_error(
          model.login,
          "That email and password didn't match. Try again.",
        )
      #(Model(..model, login: login_model), effect.none())
    }

    RegisterResponse(Ok(response)) -> {
      save_token(response.token)
      let user =
        User(
          id: response.user.id,
          email: response.user.email,
          display_name: response.user.display_name,
        )
      enter_session(model, user, response.token)
    }

    RegisterResponse(Error(error)) -> {
      let message = case error {
        api.ServerError(409, _) ->
          "An account with that email already exists. Sign in instead."
        _ -> api.error_message(error)
      }
      let register_model = register.set_error(model.register, message)
      #(Model(..model, register: register_model), effect.none())
    }

    MeResponse(Ok(api_user)) -> {
      let user =
        User(
          id: api_user.id,
          email: api_user.email,
          display_name: api_user.display_name,
        )
      let token = option.unwrap(model.session_token, "")
      enter_session(model, user, token)
    }

    MeResponse(Error(error)) -> {
      // Only a genuine auth failure means the token is bad. A transient network
      // or server error should not discard a token that may still be valid.
      case api.is_session_expired(error) {
        True -> expire_session(model)
        False -> #(model, effect.none())
      }
    }

    AuthConfigResponse(Ok(config)) -> {
      let route = case config.password_auth, model.route {
        False, router.Register -> router.Login
        _, route -> route
      }
      let nav_effect = case route != model.route {
        True -> modem.push("/admin/login", None, None)
        False -> effect.none()
      }
      #(
        Model(..model, password_auth: config.password_auth, route: route),
        nav_effect,
      )
    }

    // Keep password auth enabled if this optional capability probe fails.
    AuthConfigResponse(Error(_)) -> #(model, effect.none())

    LogoutResponse(_) -> {
      clear_token()
      let model =
        Model(
          ..model,
          user: None,
          session_token: None,
          route: router.Login,
          flash_message: None,
        )
      #(model, modem.push("/admin/login", None, None))
    }

    TenantsResponse(Ok(tenant_list)) -> {
      let tenant_models =
        list.map(tenant_list.tenants, fn(t) {
          tenants.Tenant(id: t.id, name: t.name)
        })
      let tenants_model =
        tenants.update(model.tenants, tenants.TenantsLoaded(tenant_models)).0
      #(Model(..model, tenants: tenants_model), effect.none())
    }

    TenantsResponse(Error(error)) -> {
      use <- handle_error(model, error)
      let tenants_model =
        tenants.update(
          model.tenants,
          tenants.LoadError(
            "Couldn't load tenants. " <> api.error_message(error),
          ),
        ).0
      #(Model(..model, tenants: tenants_model), effect.none())
    }

    DashboardTenantsResponse(Ok(tenant_list)) -> {
      let tenant_models =
        list.map(tenant_list.tenants, fn(t) {
          dashboard.Tenant(id: t.id, name: t.name)
        })
      let dashboard_model =
        dashboard.update(
          model.dashboard,
          dashboard.TenantsLoaded(tenant_models),
        ).0
      #(Model(..model, dashboard: dashboard_model), effect.none())
    }

    DashboardTenantsResponse(Error(error)) -> {
      use <- handle_error(model, error)
      let dashboard_model =
        dashboard.update(
          model.dashboard,
          dashboard.LoadError(
            "Couldn't load tenants. " <> api.error_message(error),
          ),
        ).0
      #(Model(..model, dashboard: dashboard_model), effect.none())
    }

    CreateTenantResponse(Ok(tenant_with_secrets)) -> {
      let detail_model =
        tenant_detail.init(tenant_with_secrets.id)
        |> tenant_detail.set_loaded_with_secrets(
          tenant_with_secrets.name,
          tenant_with_secrets.secret1,
          tenant_with_secrets.secret2,
        )
      let model =
        Model(
          ..model,
          route: router.TenantDetail(tenant_with_secrets.id),
          tenant_new: tenant_new.init(),
          tenant_detail: detail_model,
          flash_message: Some(
            "Tenant created. Copy both secrets before leaving this page.",
          ),
        )
      #(
        model,
        modem.push("/admin/tenants/" <> tenant_with_secrets.id, None, None),
      )
    }

    CreateTenantResponse(Error(error)) -> {
      use <- handle_error(model, error)
      let tenant_new_model =
        tenant_new.set_error(
          model.tenant_new,
          "Couldn't create the tenant. " <> api.error_message(error),
        )
      #(Model(..model, tenant_new: tenant_new_model), effect.none())
    }

    GetTenantResponse(Ok(tenant)) -> {
      let detail_model =
        tenant_detail.set_loaded(
          model.tenant_detail,
          tenant.name,
          tenant.secret1,
          tenant.secret2,
        )
      #(Model(..model, tenant_detail: detail_model), effect.none())
    }

    GetTenantResponse(Error(api.ServerError(404, _))) -> {
      let detail_model = tenant_detail.set_not_found(model.tenant_detail)
      #(Model(..model, tenant_detail: detail_model), effect.none())
    }

    GetTenantResponse(Error(error)) -> {
      use <- handle_error(model, error)
      let detail_model =
        tenant_detail.set_error(
          model.tenant_detail,
          "Couldn't load this tenant. " <> api.error_message(error),
        )
      #(Model(..model, tenant_detail: detail_model), effect.none())
    }

    RegenerateSecretResponse(slot, Ok(response)) -> {
      let detail_model =
        tenant_detail.set_regenerate_success(
          model.tenant_detail,
          slot,
          response.secret,
        )
      #(Model(..model, tenant_detail: detail_model), effect.none())
    }

    RegenerateSecretResponse(slot, Error(error)) -> {
      use <- handle_error(model, error)
      let detail_model =
        tenant_detail.set_regenerate_error(
          model.tenant_detail,
          slot,
          "Couldn't rotate this secret. Existing tokens still work. "
            <> api.error_message(error),
        )
      #(Model(..model, tenant_detail: detail_model), effect.none())
    }

    DeleteTenantResponse(Ok(_response)) -> {
      let message =
        "Deleted tenant "
        <> model.tenant_detail.tenant_name
        <> ". Stored documents were not deleted."
      #(
        Model(..model, flash_message: Some(message)),
        modem.push("/admin/tenants", None, None),
      )
    }

    DeleteTenantResponse(Error(error)) -> {
      use <- handle_error(model, error)
      let detail_model =
        tenant_detail.set_delete_error(
          model.tenant_detail,
          "Couldn't delete this tenant. Nothing was changed. "
            <> api.error_message(error),
        )
      #(Model(..model, tenant_detail: detail_model), effect.none())
    }

    // Document list page messages
    DocumentListMsg(doc_list_msg) -> {
      let #(doc_list_model, doc_list_effect) =
        document_list.update(model.document_list, doc_list_msg)
      let mapped_effect = effect.map(doc_list_effect, DocumentListMsg)

      case doc_list_msg {
        document_list.Retry ->
          case model.session_token {
            Some(token) -> #(
              Model(..model, document_list: doc_list_model),
              api.list_documents(
                token,
                doc_list_model.tenant_id,
                DocumentListResponse,
              ),
            )
            None -> #(
              Model(..model, document_list: doc_list_model),
              mapped_effect,
            )
          }
        _ -> #(Model(..model, document_list: doc_list_model), mapped_effect)
      }
    }

    // Document detail page messages
    DocumentDetailMsg(doc_detail_msg) -> {
      let #(doc_detail_model, doc_detail_effect) =
        document_detail.update(model.document_detail, doc_detail_msg)
      let mapped_effect = effect.map(doc_detail_effect, DocumentDetailMsg)

      // Handle pending actions that need API calls
      let api_effect = case model.session_token {
        Some(token) -> {
          let tid = doc_detail_model.tenant_id
          let did = doc_detail_model.document_id

          // Only the idle-to-loading transition starts a request. Other page
          // messages cannot duplicate a request that is already in flight.
          let deltas_effect = case
            model.document_detail.deltas_loading,
            doc_detail_model.deltas_loading
          {
            False, True ->
              api.get_document_deltas(
                token,
                tid,
                did,
                doc_detail_model.deltas_from,
                document_detail.page_size,
                DocumentDeltasResponse,
              )
            _, _ -> effect.none()
          }

          let git_effect = case
            model.document_detail.git_loading,
            doc_detail_model.git_loading
          {
            False, True ->
              case doc_detail_model.git_view {
                document_detail.GitBlobView(sha, None) ->
                  api.get_admin_blob(token, tid, sha, GitBlobResponse)
                document_detail.GitTreeView(sha, None) ->
                  api.get_admin_tree(token, tid, sha, False, GitTreeResponse)
                document_detail.GitCommitView(sha, None) ->
                  api.get_admin_commit(token, tid, sha, GitCommitResponse)
                _ -> effect.none()
              }
            _, _ -> effect.none()
          }

          effect.batch([deltas_effect, git_effect])
        }
        None -> effect.none()
      }

      #(
        Model(..model, document_detail: doc_detail_model),
        effect.batch([mapped_effect, api_effect]),
      )
    }

    // Tenant document count response (for tenant detail page)
    TenantDocumentCountResponse(Ok(resp)) -> {
      let count = list.length(resp.documents)
      let detail_model =
        tenant_detail.set_document_count(model.tenant_detail, count)
      #(Model(..model, tenant_detail: detail_model), effect.none())
    }

    TenantDocumentCountResponse(Error(_)) -> #(model, effect.none())

    // Document list API response
    DocumentListResponse(Ok(resp)) -> {
      let doc_models =
        list.map(resp.documents, fn(d) {
          document_list.Document(
            id: d.id,
            tenant_id: d.tenant_id,
            sequence_number: d.sequence_number,
            session_alive: d.session_alive,
          )
        })
      let doc_list_model =
        document_list.update(
          model.document_list,
          document_list.DocumentsLoaded(doc_models),
        ).0
      #(Model(..model, document_list: doc_list_model), effect.none())
    }

    DocumentListResponse(Error(error)) -> {
      use <- handle_error(model, error)
      let doc_list_model =
        document_list.update(
          model.document_list,
          document_list.LoadError(
            "Couldn't load documents. " <> api.error_message(error),
          ),
        ).0
      #(Model(..model, document_list: doc_list_model), effect.none())
    }

    // Document detail API response
    DocumentDetailResponse(Ok(resp)) -> {
      let doc_detail_model =
        document_detail.update(
          model.document_detail,
          document_detail.DocumentLoaded(resp),
        ).0
      #(Model(..model, document_detail: doc_detail_model), effect.none())
    }

    DocumentDetailResponse(Error(api.ServerError(404, _))) -> {
      let doc_detail_model =
        document_detail.update(
          model.document_detail,
          document_detail.DocumentLoadError("Document not found"),
        ).0
      #(Model(..model, document_detail: doc_detail_model), effect.none())
    }

    DocumentDetailResponse(Error(error)) -> {
      use <- handle_error(model, error)
      let doc_detail_model =
        document_detail.update(
          model.document_detail,
          document_detail.DocumentLoadError(
            "Couldn't load this document. " <> api.error_message(error),
          ),
        ).0
      #(Model(..model, document_detail: doc_detail_model), effect.none())
    }

    DocumentDeltasResponse(Ok(resp)) -> {
      let doc_detail_model =
        document_detail.update(
          model.document_detail,
          document_detail.DeltasLoaded(resp.deltas),
        ).0
      #(Model(..model, document_detail: doc_detail_model), effect.none())
    }

    DocumentDeltasResponse(Error(error)) -> {
      use <- handle_error(model, error)
      let doc_detail_model =
        document_detail.update(
          model.document_detail,
          document_detail.DeltasLoadError(api.error_message(error)),
        ).0
      #(Model(..model, document_detail: doc_detail_model), effect.none())
    }

    DocumentSummariesResponse(Ok(resp)) -> {
      let doc_detail_model =
        document_detail.update(
          model.document_detail,
          document_detail.SummariesLoaded(resp.summaries),
        ).0
      #(Model(..model, document_detail: doc_detail_model), effect.none())
    }

    DocumentSummariesResponse(Error(error)) -> {
      use <- handle_error(model, error)
      let doc_detail_model =
        document_detail.update(
          model.document_detail,
          document_detail.SummariesLoadError(api.error_message(error)),
        ).0
      #(Model(..model, document_detail: doc_detail_model), effect.none())
    }

    DocumentRefsResponse(Ok(resp)) -> {
      let doc_detail_model =
        document_detail.update(
          model.document_detail,
          document_detail.RefsLoaded(resp.refs),
        ).0
      #(Model(..model, document_detail: doc_detail_model), effect.none())
    }

    DocumentRefsResponse(Error(error)) -> {
      use <- handle_error(model, error)
      let doc_detail_model =
        document_detail.update(
          model.document_detail,
          document_detail.RefsLoadError(api.error_message(error)),
        ).0
      #(Model(..model, document_detail: doc_detail_model), effect.none())
    }

    GitBlobResponse(Ok(resp)) -> {
      let doc_detail_model =
        document_detail.update(
          model.document_detail,
          document_detail.BlobLoaded(resp.blob),
        ).0
      #(Model(..model, document_detail: doc_detail_model), effect.none())
    }

    GitBlobResponse(Error(error)) -> {
      use <- handle_error(model, error)
      let doc_detail_model =
        document_detail.update(
          model.document_detail,
          document_detail.GitLoadError(api.error_message(error)),
        ).0
      #(Model(..model, document_detail: doc_detail_model), effect.none())
    }

    GitTreeResponse(Ok(resp)) -> {
      let doc_detail_model =
        document_detail.update(
          model.document_detail,
          document_detail.TreeLoaded(resp.tree),
        ).0
      #(Model(..model, document_detail: doc_detail_model), effect.none())
    }

    GitTreeResponse(Error(error)) -> {
      use <- handle_error(model, error)
      let doc_detail_model =
        document_detail.update(
          model.document_detail,
          document_detail.GitLoadError(api.error_message(error)),
        ).0
      #(Model(..model, document_detail: doc_detail_model), effect.none())
    }

    GitCommitResponse(Ok(resp)) -> {
      let doc_detail_model =
        document_detail.update(
          model.document_detail,
          document_detail.CommitLoaded(resp.commit),
        ).0
      #(Model(..model, document_detail: doc_detail_model), effect.none())
    }

    GitCommitResponse(Error(error)) -> {
      use <- handle_error(model, error)
      let doc_detail_model =
        document_detail.update(
          model.document_detail,
          document_detail.GitLoadError(api.error_message(error)),
        ).0
      #(Model(..model, document_detail: doc_detail_model), effect.none())
    }

    Logout -> {
      case model.session_token {
        Some(token) -> #(model, api.logout(token, LogoutResponse))
        None -> update(model, LogoutResponse(Error(api.NetworkError(""))))
      }
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// View
// ─────────────────────────────────────────────────────────────────────────────

fn view(model: Model) -> Element(Msg) {
  div([class("app")], [view_route_announcer(model.route), view_content(model)])
}

/// Off-screen live region that names the current view. Because it stays in the
/// DOM and only its text changes, screen readers announce SPA navigation that
/// would otherwise be silent.
fn view_route_announcer(route: Route) -> Element(Msg) {
  div(
    [class("sr-only"), attribute.role("status"), attribute.aria_live("polite")],
    [text(announce_label(route))],
  )
}

fn announce_label(route: Route) -> String {
  case route {
    router.Login -> "Sign in"
    router.Register -> "Create account"
    router.Dashboard -> "Dashboard"
    router.Tenants -> "Tenants"
    router.TenantNew -> "Create tenant"
    router.TenantDetail(_) -> "Tenant detail"
    router.DocumentList(_) -> "Documents"
    router.DocumentDetail(_, _) -> "Document detail"
    router.NotFound -> "Page not found"
  }
}

fn view_content(model: Model) -> Element(Msg) {
  case model.route {
    router.Login ->
      element.map(login.view(model.login, model.password_auth), LoginMsg)

    router.Register ->
      case model.password_auth {
        True -> element.map(register.view(model.register), RegisterMsg)
        False -> element.map(login.view(model.login, False), LoginMsg)
      }

    router.Dashboard ->
      view_authenticated_layout(
        model,
        element.map(dashboard.view(model.dashboard), DashboardMsg),
      )

    router.Tenants ->
      view_authenticated_layout(
        model,
        element.map(tenants.view(model.tenants), TenantsMsg),
      )

    router.TenantNew ->
      view_authenticated_layout(
        model,
        element.map(tenant_new.view(model.tenant_new), TenantNewMsg),
      )

    router.TenantDetail(_id) ->
      view_authenticated_layout(
        model,
        element.map(tenant_detail.view(model.tenant_detail), TenantDetailMsg),
      )

    router.DocumentList(_tid) ->
      view_authenticated_layout(
        model,
        element.map(document_list.view(model.document_list), DocumentListMsg),
      )

    router.DocumentDetail(_tid, _did) ->
      view_authenticated_layout(
        model,
        element.map(
          document_detail.view(model.document_detail),
          DocumentDetailMsg,
        ),
      )

    router.NotFound -> view_not_found()
  }
}

fn view_authenticated_layout(
  model: Model,
  content: Element(Msg),
) -> Element(Msg) {
  div([class("authenticated-layout")], [
    html.a([class("skip-link"), attribute.href("#main-content")], [
      text("Skip to content"),
    ]),
    view_nav(model),
    html.main([class("main-content"), attribute.id("main-content")], [
      view_flash(model.flash_message),
      content,
    ]),
  ])
}

fn view_flash(message: Option(String)) -> Element(Msg) {
  case message {
    None -> element.none()
    Some(message) ->
      div(
        [
          class("alert alert-success app-flash"),
          attribute.role("status"),
          attribute.aria_live("polite"),
        ],
        [
          p([class("alert-message")], [text(message)]),
          html.button(
            [
              class("flash-dismiss"),
              attribute.type_("button"),
              event.on_click(DismissFlash),
            ],
            [text("Dismiss")],
          ),
        ],
      )
  }
}

fn view_nav(model: Model) -> Element(Msg) {
  let user_name = case model.user {
    Some(user) -> user.display_name
    None -> "Guest"
  }
  let dashboard_active = model.route == router.Dashboard
  let tenants_active = case model.route {
    router.Tenants
    | router.TenantNew
    | router.TenantDetail(_)
    | router.DocumentList(_)
    | router.DocumentDetail(_, _) -> True
    _ -> False
  }

  nav([class("nav"), attribute.aria_label("Primary")], [
    div([class("nav-brand")], [
      html.a([attribute.href("/admin/dashboard")], [
        html.span([class("brand-name")], [text("Floodgate Admin")]),
      ]),
    ]),
    div([class("nav-links")], [
      view_nav_link("Dashboard", "/admin/dashboard", dashboard_active),
      view_nav_link("Tenants", "/admin/tenants", tenants_active),
    ]),
    div([class("nav-user")], [
      p([], [text(user_name)]),
      html.button([attribute.type_("button"), event.on_click(Logout)], [
        text("Logout"),
      ]),
    ]),
  ])
}

fn view_nav_link(label: String, path: String, active: Bool) -> Element(Msg) {
  let attrs = case active {
    True -> [
      class("nav-link nav-link-active"),
      attribute.href(path),
      attribute.aria_current("page"),
    ]
    False -> [class("nav-link"), attribute.href(path)]
  }
  html.a(attrs, [text(label)])
}

fn view_not_found() -> Element(Msg) {
  div([class("page not-found")], [
    h1([], [text("404 - Not Found")]),
    p([], [text("The page you're looking for doesn't exist.")]),
    html.a([attribute.href("/admin/login")], [text("Go to Login")]),
  ])
}

// ─────────────────────────────────────────────────────────────────────────────
// Main
// ─────────────────────────────────────────────────────────────────────────────

pub fn main() {
  let app = lustre.application(init, update, view)
  let assert Ok(_) = lustre.start(app, "#app", Nil)
  Nil
}
