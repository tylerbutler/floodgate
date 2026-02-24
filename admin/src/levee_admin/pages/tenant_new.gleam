//// Create tenant form page — only requires a name, server generates everything else.

import gleam/option.{type Option, None, Some}
import gleam/string
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

pub type FormState {
  Idle
  Submitting
  Error(String)
}

pub type Model {
  Model(name: String, state: FormState, pending_submit: Option(String))
}

pub fn init() -> Model {
  Model(name: "", state: Idle, pending_submit: None)
}

pub fn start_loading(model: Model) -> Model {
  Model(..model, state: Submitting, pending_submit: None)
}

pub fn set_error(model: Model, error: String) -> Model {
  Model(..model, state: Error(error))
}

pub fn get_pending_submit(model: Model) -> Option(String) {
  model.pending_submit
}

// ─────────────────────────────────────────────────────────────────────────────
// Messages
// ─────────────────────────────────────────────────────────────────────────────

pub type Msg {
  UpdateName(String)
  Submit
}

// ─────────────────────────────────────────────────────────────────────────────
// Update
// ─────────────────────────────────────────────────────────────────────────────

pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    UpdateName(name) -> #(Model(..model, name: name), effect.none())

    Submit -> {
      let trimmed = string.trim(model.name)
      case string.is_empty(trimmed) {
        True -> #(
          Model(..model, state: Error("Name is required")),
          effect.none(),
        )
        False -> #(Model(..model, pending_submit: Some(trimmed)), effect.none())
      }
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// View
// ─────────────────────────────────────────────────────────────────────────────

pub fn view(model: Model) -> Element(Msg) {
  let is_submitting = case model.state {
    Submitting -> True
    _ -> False
  }

  div([class("page tenant-new-page")], [
    div([class("page-header")], [
      a([class("back-link"), attribute.href("/admin/tenants")], [
        text("Back to Tenants"),
      ]),
      h1([class("page-title")], [text("Create Tenant")]),
    ]),
    div([class("card form-card")], [
      view_error(model.state),
      form([class("tenant-form"), event.on_submit(fn(_) { Submit })], [
        div([class("form-group")], [
          label([for("name")], [text("Name")]),
          input([
            type_("text"),
            id("name"),
            placeholder("My Application"),
            value(model.name),
            event.on_input(UpdateName),
            attribute.required(True),
          ]),
          p([class("form-help")], [
            text(
              "A display name for this tenant. The tenant ID and secrets will be generated automatically.",
            ),
          ]),
        ]),
        button(
          [type_("submit"), class("btn btn-primary"), disabled(is_submitting)],
          [
            case is_submitting {
              True -> text("Creating...")
              False -> text("Create Tenant")
            },
          ],
        ),
      ]),
    ]),
  ])
}

fn view_error(state: FormState) -> Element(Msg) {
  case state {
    Error(message) ->
      div([class("alert alert-error")], [
        span([class("alert-icon")], [text("!")]),
        span([class("alert-message")], [text(message)]),
      ])
    _ -> element.none()
  }
}
