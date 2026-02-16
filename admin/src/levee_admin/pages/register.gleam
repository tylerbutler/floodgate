//// Register page component.

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
    confirm_password: String,
    display_name: String,
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
    confirm_password: "",
    display_name: "",
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
  UpdateConfirmPassword(String)
  UpdateDisplayName(String)
  Submit
}

/// Data emitted when form is submitted
pub type SubmitData {
  SubmitData(email: String, password: String, display_name: String)
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

    UpdateConfirmPassword(password) -> #(
      Model(..model, confirm_password: password),
      effect.none(),
    )

    UpdateDisplayName(name) -> #(
      Model(..model, display_name: name),
      effect.none(),
    )

    Submit -> {
      // Validate passwords match
      case model.password == model.confirm_password {
        False -> {
          let model = Model(..model, error: Some("Passwords do not match"))
          #(model, effect.none())
        }
        True -> {
          // Set pending_submit so parent can make API call
          let data =
            SubmitData(
              email: model.email,
              password: model.password,
              display_name: model.display_name,
            )
          #(Model(..model, pending_submit: Some(data)), effect.none())
        }
      }
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// View
// ─────────────────────────────────────────────────────────────────────────────

pub fn view(model: Model) -> Element(Msg) {
  div([class("auth-page register-page")], [
    div([class("auth-card")], [
      h1([class("auth-title")], [text("Create Account")]),
      view_error(model.error),
      form([class("auth-form"), event.on_submit(fn(_) { Submit })], [
        div([class("form-group")], [
          label([for("display_name")], [text("Display Name")]),
          input([
            type_("text"),
            id("display_name"),
            placeholder("Your name"),
            value(model.display_name),
            event.on_input(UpdateDisplayName),
          ]),
        ]),
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
            placeholder("At least 8 characters"),
            value(model.password),
            event.on_input(UpdatePassword),
            attribute.required(True),
            attribute.attribute("minlength", "8"),
          ]),
        ]),
        div([class("form-group")], [
          label([for("confirm_password")], [text("Confirm Password")]),
          input([
            type_("password"),
            id("confirm_password"),
            placeholder("Confirm your password"),
            value(model.confirm_password),
            event.on_input(UpdateConfirmPassword),
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
              True -> text("Creating account...")
              False -> text("Create Account")
            },
          ],
        ),
      ]),
      p([class("auth-footer")], [
        text("Already have an account? "),
        a([attribute.href("/admin/login")], [text("Sign in")]),
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
