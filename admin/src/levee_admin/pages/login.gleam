//// Login page component.

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
    pending_submit: None,
  )
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
      // Set pending_submit so parent can make API call
      let data = SubmitData(email: model.email, password: model.password)
      #(Model(..model, pending_submit: Some(data)), effect.none())
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// View
// ─────────────────────────────────────────────────────────────────────────────

pub fn view(model: Model) -> Element(Msg) {
  div([class("auth-page login-page")], [
    div([class("auth-card")], [
      h1([class("auth-title")], [text("Sign In")]),
      view_error(model.error),
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
            disabled(model.loading),
          ],
          [
            case model.loading {
              True -> text("Signing in...")
              False -> text("Sign In")
            },
          ],
        ),
      ]),
      p([class("auth-footer")], [
        text("Don't have an account? "),
        a([attribute.href("/admin/register")], [text("Register")]),
      ]),
    ]),
  ])
}

fn view_error(error: Option(String)) -> Element(Msg) {
  case error {
    Some(message) ->
      div([class("alert alert-error")], [
        span([class("alert-icon")], [text("!")]),
        span([class("alert-message")], [text(message)]),
      ])
    None -> element.none()
  }
}
