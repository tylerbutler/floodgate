//// Levee Admin - Tenant Management UI
////
//// A Lustre-based single-page application for managing tenants,
//// users, and document access in Levee.

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

@external(javascript, "./levee_admin_ffi.mjs", "get_query_param")
fn get_query_param(name: String) -> Option(String)

@external(javascript, "./levee_admin_ffi.mjs", "navigate_to")
fn do_navigate_to(url: String) -> Nil

@external(javascript, "./levee_admin_ffi.mjs", "get_current_path")
fn get_current_path() -> String

@external(javascript, "./levee_admin_ffi.mjs", "save_token")
fn save_token(token: String) -> Nil

@external(javascript, "./levee_admin_ffi.mjs", "load_token")
fn load_token() -> Option(String)

@external(javascript, "./levee_admin_ffi.mjs", "clear_token")
fn clear_token() -> Nil

import levee_admin/api
import levee_admin/pages/dashboard
import levee_admin/pages/document_detail
import levee_admin/pages/document_list
import levee_admin/pages/login
import levee_admin/pages/register
import levee_admin/pages/tenant_detail
import levee_admin/pages/tenant_new
import levee_admin/pages/tenants
import levee_admin/router.{type Route}

// ─────────────────────────────────────────────────────────────────────────────
// Model
// ─────────────────────────────────────────────────────────────────────────────

pub type Model {
  Model(
    route: Route,
    user: Option(User),
    session_token: Option(String),
    login: login.Model,
    register: register.Model,
    dashboard: dashboard.Model,
    tenants: tenants.Model,
    tenant_new: tenant_new.Model,
    tenant_detail: tenant_detail.Model,
    document_list: document_list.Model,
    document_detail: document_detail.Model,
  )
}

pub type User {
  User(id: String, email: String, display_name: String)
}

fn init(_flags) -> #(Model, Effect(Msg)) {
  // Check if we're returning from OAuth with a token in the URL,
  // or restore a previously saved token from localStorage
  let #(session_token, oauth_effect) = case get_query_param("token") {
    Some(token) -> {
      save_token(token)
      #(Some(token), api.get_me(token, MeResponse))
    }
    None ->
      case load_token() {
        Some(token) -> #(Some(token), api.get_me(token, MeResponse))
        None -> #(None, effect.none())
      }
  }

  // Parse the initial route from the current URL path,
  // applying auth guards for protected routes
  let initial_route = case uri.parse(get_current_path()) {
    Ok(parsed_uri) -> router.parse(parsed_uri)
    Error(_) -> router.Login
  }
  let initial_route = case session_token, initial_route {
    None, router.Dashboard -> router.Login
    None, router.Tenants -> router.Login
    None, router.TenantNew -> router.Login
    None, router.TenantDetail(_) -> router.Login
    None, router.DocumentList(_) -> router.Login
    None, router.DocumentDetail(_, _) -> router.Login
    _, route -> route
  }

  let model =
    Model(
      route: initial_route,
      user: None,
      session_token: session_token,
      login: login.init(),
      register: register.init(),
      dashboard: dashboard.init(),
      tenants: tenants.init(),
      tenant_new: tenant_new.init(),
      tenant_detail: tenant_detail.init(""),
      document_list: document_list.init(""),
      document_detail: document_detail.init("", ""),
    )

  #(model, effect.batch([modem.init(on_url_change), oauth_effect]))
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
  Logout
}

fn on_url_change(uri: Uri) -> Msg {
  OnRouteChange(router.parse(uri))
}

// ─────────────────────────────────────────────────────────────────────────────
// Update
// ─────────────────────────────────────────────────────────────────────────────

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    OnRouteChange(route) -> {
      // Redirect to login if not authenticated and trying to access protected route
      let route = case model.session_token, route {
        None, router.Dashboard -> router.Login
        None, router.Tenants -> router.Login
        None, router.TenantNew -> router.Login
        None, router.TenantDetail(_) -> router.Login
        None, router.DocumentList(_) -> router.Login
        None, router.DocumentDetail(_, _) -> router.Login
        _, r -> r
      }

      let effect = case route, model.session_token {
        router.Dashboard, Some(token) ->
          api.list_tenants(token, DashboardTenantsResponse)
        router.Tenants, Some(token) -> api.list_tenants(token, TenantsResponse)
        router.TenantDetail(id), Some(token) ->
          effect.batch([
            api.get_tenant(token, id, GetTenantResponse),
            api.list_documents(token, id, TenantDocumentCountResponse),
          ])
        router.DocumentList(tid), Some(token) ->
          api.list_documents(token, tid, DocumentListResponse)
        router.DocumentDetail(tid, did), Some(token) ->
          effect.batch([
            api.get_document(token, tid, did, DocumentDetailResponse),
            api.get_document_deltas(
              token,
              tid,
              did,
              -1,
              100,
              DocumentDeltasResponse,
            ),
            api.get_document_summaries(
              token,
              tid,
              did,
              DocumentSummariesResponse,
            ),
            api.get_document_refs(token, tid, DocumentRefsResponse),
          ])
        _, _ -> effect.none()
      }

      let model = case route {
        router.Tenants -> Model(..model, route: route, tenants: tenants.init())
        router.TenantNew ->
          Model(..model, route: route, tenant_new: tenant_new.init())
        router.TenantDetail(id) ->
          Model(..model, route: route, tenant_detail: tenant_detail.init(id))
        router.Dashboard ->
          Model(
            ..model,
            route: route,
            dashboard: dashboard.start_loading(dashboard.init()),
          )
        router.DocumentList(tid) ->
          Model(..model, route: route, document_list: document_list.init(tid))
        router.DocumentDetail(tid, did) ->
          Model(
            ..model,
            route: route,
            document_detail: document_detail.init(tid, did),
          )
        _ -> Model(..model, route: route)
      }

      #(model, effect)
    }

    LoginMsg(login.GitHubLogin) -> {
      // Redirect to GitHub OAuth — full page navigation
      #(model, effect.from(fn(_dispatch) { do_navigate_to("/auth/github") }))
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
      let model =
        Model(
          ..model,
          user: Some(user),
          session_token: Some(response.token),
          route: router.Dashboard,
          login: login.init(),
        )
      let nav_effect = modem.push("/admin/dashboard", None, None)
      let load_effect =
        api.list_tenants(response.token, DashboardTenantsResponse)
      #(model, effect.batch([nav_effect, load_effect]))
    }

    LoginResponse(Error(_error)) -> {
      let login_model =
        login.set_error(model.login, "Invalid email or password")
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
      let model =
        Model(
          ..model,
          user: Some(user),
          session_token: Some(response.token),
          route: router.Dashboard,
          register: register.init(),
        )
      let nav_effect = modem.push("/admin/dashboard", None, None)
      let load_effect =
        api.list_tenants(response.token, DashboardTenantsResponse)
      #(model, effect.batch([nav_effect, load_effect]))
    }

    RegisterResponse(Error(_error)) -> {
      let register_model =
        register.set_error(model.register, "Registration failed")
      #(Model(..model, register: register_model), effect.none())
    }

    MeResponse(Ok(api_user)) -> {
      let user =
        User(
          id: api_user.id,
          email: api_user.email,
          display_name: api_user.display_name,
        )
      let model = Model(..model, user: Some(user), route: router.Dashboard)
      let nav_effect = modem.push("/admin/dashboard", None, None)
      case model.session_token {
        Some(token) -> {
          let load_effect = api.list_tenants(token, DashboardTenantsResponse)
          #(model, effect.batch([nav_effect, load_effect]))
        }
        None -> #(model, nav_effect)
      }
    }

    MeResponse(Error(_error)) -> {
      // Token was invalid — clear it and stay on login
      clear_token()
      #(Model(..model, session_token: None), effect.none())
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

    TenantsResponse(Error(_error)) -> {
      let tenants_model =
        tenants.update(
          model.tenants,
          tenants.LoadError("Failed to load tenants"),
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

    DashboardTenantsResponse(Error(_error)) -> {
      let dashboard_model =
        dashboard.update(
          model.dashboard,
          dashboard.LoadError("Failed to load tenants"),
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
          tenant_new: tenant_new.init(),
          tenant_detail: detail_model,
        )
      #(
        model,
        modem.push("/admin/tenants/" <> tenant_with_secrets.id, None, None),
      )
    }

    CreateTenantResponse(Error(_error)) -> {
      let tenant_new_model =
        tenant_new.set_error(model.tenant_new, "Failed to create tenant")
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

    GetTenantResponse(Error(_error)) -> {
      let detail_model =
        tenant_detail.set_error(model.tenant_detail, "Failed to load tenant")
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

    RegenerateSecretResponse(slot, Error(_error)) -> {
      let detail_model =
        tenant_detail.set_regenerate_error(
          model.tenant_detail,
          slot,
          "Failed to regenerate secret",
        )
      #(Model(..model, tenant_detail: detail_model), effect.none())
    }

    DeleteTenantResponse(Ok(_response)) -> {
      #(model, modem.push("/admin/tenants", None, None))
    }

    DeleteTenantResponse(Error(_error)) -> {
      let detail_model =
        tenant_detail.set_delete_error(
          model.tenant_detail,
          "Failed to delete tenant",
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

          // Check for pending deltas load
          let deltas_effect = case
            document_detail.get_pending_deltas_load(doc_detail_model)
          {
            True ->
              api.get_document_deltas(
                token,
                tid,
                did,
                doc_detail_model.deltas_from,
                100,
                DocumentDeltasResponse,
              )
            False -> effect.none()
          }

          // Check for pending git object load
          let git_effect = case
            document_detail.get_pending_git_action(doc_detail_model)
          {
            document_detail.GitBlobView(sha, None) ->
              api.get_admin_blob(token, tid, sha, GitBlobResponse)
            document_detail.GitTreeView(sha, None) ->
              api.get_admin_tree(token, tid, sha, False, GitTreeResponse)
            document_detail.GitCommitView(sha, None) ->
              api.get_admin_commit(token, tid, sha, GitCommitResponse)
            _ -> effect.none()
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

    DocumentListResponse(Error(_)) -> {
      let doc_list_model =
        document_list.update(
          model.document_list,
          document_list.LoadError("Failed to load documents"),
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

    DocumentDetailResponse(Error(_)) -> {
      let doc_detail_model =
        document_detail.update(
          model.document_detail,
          document_detail.DocumentLoadError("Failed to load document"),
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

    DocumentDeltasResponse(Error(_)) -> {
      let doc_detail_model =
        document_detail.update(
          model.document_detail,
          document_detail.DeltasLoadError("Failed to load deltas"),
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

    DocumentSummariesResponse(Error(_)) -> {
      let doc_detail_model =
        document_detail.update(
          model.document_detail,
          document_detail.SummariesLoadError("Failed to load summaries"),
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

    DocumentRefsResponse(Error(_)) -> {
      let doc_detail_model =
        document_detail.update(
          model.document_detail,
          document_detail.RefsLoadError("Failed to load refs"),
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

    GitBlobResponse(Error(_)) -> {
      let doc_detail_model =
        document_detail.update(
          model.document_detail,
          document_detail.GitLoadError("Failed to load blob"),
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

    GitTreeResponse(Error(_)) -> {
      let doc_detail_model =
        document_detail.update(
          model.document_detail,
          document_detail.GitLoadError("Failed to load tree"),
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

    GitCommitResponse(Error(_)) -> {
      let doc_detail_model =
        document_detail.update(
          model.document_detail,
          document_detail.GitLoadError("Failed to load commit"),
        ).0
      #(Model(..model, document_detail: doc_detail_model), effect.none())
    }

    Logout -> {
      clear_token()
      let model =
        Model(..model, user: None, session_token: None, route: router.Login)
      #(model, modem.push("/admin/login", None, None))
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// View
// ─────────────────────────────────────────────────────────────────────────────

fn view(model: Model) -> Element(Msg) {
  div([class("app")], [view_content(model)])
}

fn view_content(model: Model) -> Element(Msg) {
  case model.route {
    router.Login -> element.map(login.view(model.login), LoginMsg)

    router.Register -> element.map(register.view(model.register), RegisterMsg)

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
    view_nav(model),
    html.main([class("main-content")], [content]),
  ])
}

fn view_nav(model: Model) -> Element(Msg) {
  let user_name = case model.user {
    Some(user) -> user.display_name
    None -> "Guest"
  }

  nav([class("nav")], [
    div([class("nav-brand")], [h1([], [text("Levee Admin")])]),
    div([class("nav-user")], [
      p([], [text(user_name)]),
      html.button([attribute.type_("button"), event.on_click(Logout)], [
        text("Logout"),
      ]),
    ]),
  ])
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
