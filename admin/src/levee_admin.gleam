//// Levee Admin - Tenant Management UI
////
//// A Lustre-based single-page application for managing tenants,
//// users, and document access in Levee.

import gleam/option.{type Option, None, Some}
import gleam/uri.{type Uri}
import lustre
import lustre/attribute.{class}
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html.{div, h1, nav, p, text}
import lustre/event
import modem

import levee_admin/api
import levee_admin/pages/dashboard
import levee_admin/pages/login
import levee_admin/pages/register
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
  )
}

pub type User {
  User(id: String, email: String, display_name: String)
}

fn init(_flags) -> #(Model, Effect(Msg)) {
  let model =
    Model(
      route: router.Login,
      user: None,
      session_token: None,
      login: login.init(),
      register: register.init(),
      dashboard: dashboard.init(),
    )

  #(model, modem.init(on_url_change))
}

// ─────────────────────────────────────────────────────────────────────────────
// Messages
// ─────────────────────────────────────────────────────────────────────────────

pub type Msg {
  OnRouteChange(Route)
  LoginMsg(login.Msg)
  RegisterMsg(register.Msg)
  DashboardMsg(dashboard.Msg)
  // Auth API responses
  LoginResponse(Result(api.AuthResponse, api.ApiError))
  RegisterResponse(Result(api.AuthResponse, api.ApiError))
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
        None, router.TenantDetail(_) -> router.Login
        _, r -> r
      }
      #(Model(..model, route: route), effect.none())
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

    LoginResponse(Ok(response)) -> {
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
      #(model, modem.push("/admin/dashboard", None, None))
    }

    LoginResponse(Error(_error)) -> {
      let login_model =
        login.set_error(model.login, "Invalid email or password")
      #(Model(..model, login: login_model), effect.none())
    }

    RegisterResponse(Ok(response)) -> {
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
      #(model, modem.push("/admin/dashboard", None, None))
    }

    RegisterResponse(Error(_error)) -> {
      let register_model =
        register.set_error(model.register, "Registration failed")
      #(Model(..model, register: register_model), effect.none())
    }

    Logout -> {
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
      view_authenticated_layout(model, view_tenants_placeholder())

    router.TenantDetail(id) ->
      view_authenticated_layout(model, view_tenant_detail_placeholder(id))

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

fn view_tenants_placeholder() -> Element(Msg) {
  div([class("page tenants")], [
    h1([], [text("Tenants")]),
    p([], [text("Tenant list coming soon...")]),
  ])
}

fn view_tenant_detail_placeholder(id: String) -> Element(Msg) {
  div([class("page tenant-detail")], [
    h1([], [text("Tenant: " <> id)]),
    p([], [text("Tenant details coming soon...")]),
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
