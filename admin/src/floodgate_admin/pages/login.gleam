//// Floodgate admin login page.

import gleam/option.{type Option, None, Some}
import lustre/attribute.{class, disabled, for, id, placeholder, type_, value}
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html.{
  a, button, div, form, h1, input, label, p, span, text,
}
import lustre/event

// ─────────────────────────────────────────────────────────────────────────────
// Model
// ─────────────────────────────────────────────────────────────────────────────

pub type Model {
  Model(
    email: String,
    password: String,
    error: Option(String),
    loading: Bool,
    /// True once the operator chose GitHub sign-in and a full-page redirect to
    /// the OAuth provider is under way.
    github_redirecting: Bool,
    /// Set when form is submitted; parent should check and make API call
    pending_submit: Option(SubmitData),
  )
}

pub fn init() -> Model {
  Model(
    email: "",
    password: "",
    error: None,
    loading: False,
    github_redirecting: False,
    pending_submit: None,
  )
}

/// Reflect that a GitHub OAuth redirect is starting, so the UI can show
/// progress before the browser leaves the page.
pub fn start_github_redirect(model: Model) -> Model {
  Model(..model, github_redirecting: True, error: None)
}

/// Clear the pending submit and set loading state
pub fn start_loading(model: Model) -> Model {
  Model(..model, loading: True, pending_submit: None, error: None)
}

/// Handle API error
pub fn set_error(model: Model, error: String) -> Model {
  Model(..model, loading: False, error: Some(error))
}

/// Get pending submission data if any
pub fn get_pending_submit(model: Model) -> Option(SubmitData) {
  model.pending_submit
}

// ─────────────────────────────────────────────────────────────────────────────
// Messages
// ─────────────────────────────────────────────────────────────────────────────

pub type Msg {
  UpdateEmail(String)
  UpdatePassword(String)
  Submit
  GitHubLogin
}

/// Data emitted when form is submitted
pub type SubmitData {
  SubmitData(email: String, password: String)
}

// ─────────────────────────────────────────────────────────────────────────────
// Update
// ─────────────────────────────────────────────────────────────────────────────

pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    UpdateEmail(email) -> #(Model(..model, email: email), effect.none())

    UpdatePassword(password) -> #(
      Model(..model, password: password),
      effect.none(),
    )

    Submit -> {
      // Ignore repeat submits while a sign-in is already in flight.
      case model.loading {
        True -> #(model, effect.none())
        False -> {
          let data = SubmitData(email: model.email, password: model.password)
          #(Model(..model, pending_submit: Some(data)), effect.none())
        }
      }
    }

    GitHubLogin -> {
      // Handled by parent
      #(model, effect.none())
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// View
// ─────────────────────────────────────────────────────────────────────────────

pub fn view(model: Model, password_auth: Bool) -> Element(Msg) {
  div([class("auth-page login-page")], [
    div([class("auth-card")], [
      h1([class("auth-title")], [text("Sign In")]),
      view_error(model.error),
      case password_auth {
        True ->
          form([class("auth-form"), event.on_submit(fn(_) { Submit })], [
            div([class("form-group")], [
              label([for("email")], [text("Email")]),
              input([
                type_("email"),
                id("email"),
                placeholder("you@example.com"),
                value(model.email),
                event.on_input(UpdateEmail),
                attribute.required(True),
              ]),
            ]),
            div([class("form-group")], [
              label([for("password")], [text("Password")]),
              input([
                type_("password"),
                id("password"),
                placeholder("Your password"),
                value(model.password),
                event.on_input(UpdatePassword),
                attribute.required(True),
              ]),
            ]),
            button(
              [
                type_("submit"),
                class("btn btn-primary"),
                disabled(model.loading || model.github_redirecting),
              ],
              [
                case model.loading {
                  True -> text("Signing in...")
                  False -> text("Sign In")
                },
              ],
            ),
          ])
        False -> element.none()
      },
      case password_auth {
        True -> div([class("auth-divider")], [span([], [text("or")])])
        False -> element.none()
      },
      button(
        [
          type_("button"),
          class("btn btn-github"),
          event.on_click(GitHubLogin),
          disabled(model.loading || model.github_redirecting),
        ],
        [
          case model.github_redirecting {
            True -> text("Redirecting to GitHub…")
            False -> text("Sign in with GitHub")
          },
        ],
      ),
      case model.github_redirecting {
        True ->
          p(
            [
              class("auth-footer"),
              attribute.role("status"),
              attribute.aria_live("polite"),
            ],
            [text("Taking you to GitHub to sign in…")],
          )
        False -> element.none()
      },
      case password_auth {
        True ->
          p([class("auth-footer")], [
            text("Don't have an account? "),
            a([attribute.href("/admin/register")], [text("Register")]),
          ])
        False -> element.none()
      },
    ]),
  ])
}

fn view_error(error: Option(String)) -> Element(Msg) {
  case error {
    Some(message) ->
      div([class("alert alert-error"), attribute.role("alert")], [
        span([class("alert-icon"), attribute.aria_hidden(True)], [text("!")]),
        span([class("alert-message")], [text(message)]),
      ])
    None -> element.none()
  }
}
