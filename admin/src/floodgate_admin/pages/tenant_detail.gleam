//// Floodgate tenant detail with dual secret display and per-slot rotation.

import floodgate_admin/api
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/string
import lustre/attribute.{class, disabled, type_}
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html.{a, button, code, div, h1, h2, p, span, text}
import lustre/event

@external(javascript, "../../floodgate_admin_ffi.mjs", "copy_to_clipboard")
fn copy_to_clipboard(value: String, on_result: fn(Bool) -> Nil) -> Nil

// ─────────────────────────────────────────────────────────────────────────────
// Model
// ─────────────────────────────────────────────────────────────────────────────

pub type PageState {
  Loading
  Loaded
  NotFound
  Error(String)
}

pub type SecretSlotState {
  SlotIdle
  SlotConfirming(confirmation_input: String)
  SlotSubmitting
  SlotSuccess(String)
  SlotError(String)
}

pub type DeleteState {
  DeleteHidden
  DeleteConfirming(confirmation_input: String)
  DeleteSubmitting
  DeleteError(String)
}

pub type CopyState {
  CopyIdle
  CopySuccess(String)
  CopyError(String)
}

pub type Model {
  Model(
    tenant_id: String,
    tenant_name: String,
    state: PageState,
    secret1_visible: Bool,
    secret2_visible: Bool,
    secret1_value: String,
    secret2_value: String,
    secret1_state: SecretSlotState,
    secret2_state: SecretSlotState,
    delete_state: DeleteState,
    pending_regenerate: Option(Int),
    pending_delete: Bool,
    document_count: Option(Int),
    copy_state: CopyState,
  )
}

pub fn init(tenant_id: String) -> Model {
  Model(
    tenant_id: tenant_id,
    tenant_name: "",
    state: Loading,
    secret1_visible: False,
    secret2_visible: False,
    secret1_value: "",
    secret2_value: "",
    secret1_state: SlotIdle,
    secret2_state: SlotIdle,
    delete_state: DeleteHidden,
    pending_regenerate: None,
    pending_delete: False,
    document_count: None,
    copy_state: CopyIdle,
  )
}

pub fn set_loaded(
  model: Model,
  name: String,
  secret1: String,
  secret2: String,
) -> Model {
  Model(
    ..model,
    state: Loaded,
    tenant_name: name,
    secret1_value: secret1,
    secret2_value: secret2,
  )
}

pub fn set_loaded_with_secrets(
  model: Model,
  name: String,
  secret1: String,
  secret2: String,
) -> Model {
  Model(
    ..model,
    state: Loaded,
    tenant_name: name,
    secret1_value: secret1,
    secret2_value: secret2,
    secret1_visible: True,
    secret2_visible: True,
  )
}

pub fn set_not_found(model: Model) -> Model {
  Model(..model, state: NotFound)
}

pub fn set_error(model: Model, error: String) -> Model {
  Model(..model, state: Error(error))
}

pub fn get_pending_regenerate(model: Model) -> Option(Int) {
  model.pending_regenerate
}

pub fn start_regenerate_loading(model: Model, slot: Int) -> Model {
  case slot {
    1 -> Model(..model, secret1_state: SlotSubmitting, pending_regenerate: None)
    _ -> Model(..model, secret2_state: SlotSubmitting, pending_regenerate: None)
  }
}

pub fn set_regenerate_success(
  model: Model,
  slot: Int,
  new_secret: String,
) -> Model {
  case slot {
    1 ->
      Model(
        ..model,
        secret1_state: SlotSuccess(
          "Secret 1 rotated. Copy this value and update affected clients now.",
        ),
        secret1_value: new_secret,
        secret1_visible: True,
      )
    _ ->
      Model(
        ..model,
        secret2_state: SlotSuccess(
          "Secret 2 rotated. Copy this value and update affected clients now.",
        ),
        secret2_value: new_secret,
        secret2_visible: True,
      )
  }
}

pub fn set_regenerate_error(model: Model, slot: Int, error: String) -> Model {
  case slot {
    1 -> Model(..model, secret1_state: SlotError(error))
    _ -> Model(..model, secret2_state: SlotError(error))
  }
}

pub fn start_delete_loading(model: Model) -> Model {
  Model(..model, delete_state: DeleteSubmitting, pending_delete: False)
}

pub fn get_pending_delete(model: Model) -> Bool {
  model.pending_delete
}

pub fn set_delete_error(model: Model, error: String) -> Model {
  Model(..model, delete_state: DeleteError(error))
}

pub fn set_document_count(model: Model, count: Int) -> Model {
  Model(..model, document_count: Some(count))
}

// ─────────────────────────────────────────────────────────────────────────────
// Messages
// ─────────────────────────────────────────────────────────────────────────────

pub type Msg {
  ToggleSecret1Visible
  ToggleSecret2Visible
  RequestRegenerate(Int)
  UpdateRegenerateConfirmation(Int, String)
  ConfirmRegenerate(Int)
  CancelRegenerate(Int)
  ShowDeleteConfirm
  HideDeleteConfirm
  UpdateDeleteConfirmation(String)
  ConfirmDelete
  CopyTenantId
  CopySecret(Int)
  CopyFinished(String, Bool)
}

// ─────────────────────────────────────────────────────────────────────────────
// Update
// ─────────────────────────────────────────────────────────────────────────────

pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    ToggleSecret1Visible -> #(
      Model(..model, secret1_visible: !model.secret1_visible),
      effect.none(),
    )

    ToggleSecret2Visible -> #(
      Model(..model, secret2_visible: !model.secret2_visible),
      effect.none(),
    )

    RequestRegenerate(slot) -> {
      case slot {
        1 -> #(Model(..model, secret1_state: SlotConfirming("")), effect.none())
        _ -> #(Model(..model, secret2_state: SlotConfirming("")), effect.none())
      }
    }

    UpdateRegenerateConfirmation(slot, input) -> {
      case slot {
        1 -> #(
          Model(..model, secret1_state: SlotConfirming(input)),
          effect.none(),
        )
        _ -> #(
          Model(..model, secret2_state: SlotConfirming(input)),
          effect.none(),
        )
      }
    }

    ConfirmRegenerate(slot) -> {
      let slot_state = case slot {
        1 -> model.secret1_state
        _ -> model.secret2_state
      }
      case slot_state {
        SlotConfirming("REGENERATE") -> #(
          Model(..model, pending_regenerate: Some(slot)),
          effect.none(),
        )
        _ -> #(model, effect.none())
      }
    }

    CancelRegenerate(slot) -> {
      case slot {
        1 -> #(Model(..model, secret1_state: SlotIdle), effect.none())
        _ -> #(Model(..model, secret2_state: SlotIdle), effect.none())
      }
    }

    ShowDeleteConfirm -> #(
      Model(..model, delete_state: DeleteConfirming("")),
      effect.none(),
    )

    HideDeleteConfirm -> #(
      Model(..model, delete_state: DeleteHidden),
      effect.none(),
    )

    UpdateDeleteConfirmation(input) -> #(
      Model(..model, delete_state: DeleteConfirming(input)),
      effect.none(),
    )

    ConfirmDelete -> {
      case model.delete_state {
        DeleteConfirming(input) if input == model.tenant_id -> {
          #(Model(..model, pending_delete: True), effect.none())
        }
        _ -> #(model, effect.none())
      }
    }

    CopyTenantId -> #(model, copy_effect(model.tenant_id, "Tenant ID"))

    CopySecret(slot) -> {
      let value = case slot {
        1 -> model.secret1_value
        _ -> model.secret2_value
      }
      #(model, copy_effect(value, "Secret " <> int.to_string(slot)))
    }

    CopyFinished(label, True) -> #(
      Model(..model, copy_state: CopySuccess(label <> " copied.")),
      effect.none(),
    )

    CopyFinished(label, False) -> #(
      Model(
        ..model,
        copy_state: CopyError(
          label <> " could not be copied. Select it and copy it manually.",
        ),
      ),
      effect.none(),
    )
  }
}

fn copy_effect(value: String, label: String) -> Effect(Msg) {
  effect.from(fn(dispatch) {
    copy_to_clipboard(value, fn(success) {
      dispatch(CopyFinished(label, success))
    })
    Nil
  })
}

// ─────────────────────────────────────────────────────────────────────────────
// View
// ─────────────────────────────────────────────────────────────────────────────

pub fn view(model: Model) -> Element(Msg) {
  div([class("page tenant-detail-page")], [
    div([class("page-header")], [
      a([class("back-link"), attribute.href("/admin/tenants")], [
        text("Back to Tenants"),
      ]),
      h1([class("page-title")], [text("Tenant: " <> model.tenant_name)]),
    ]),
    view_content(model),
  ])
}

fn view_content(model: Model) -> Element(Msg) {
  case model.state {
    Loading ->
      div([class("loading-state"), attribute.role("status")], [
        p([], [text("Loading tenant...")]),
      ])

    NotFound ->
      div([class("empty-state card")], [
        p([], [text("Tenant not found.")]),
        a([attribute.href("/admin/tenants")], [text("Back to Tenants")]),
      ])

    Error(message) ->
      div([class("error-state")], [
        div([class("alert alert-error"), attribute.role("alert")], [
          span([class("alert-icon")], [text("!")]),
          span([class("alert-message")], [text(message)]),
        ]),
      ])

    Loaded ->
      div([class("tenant-detail-content")], [
        view_copy_state(model.copy_state),
        view_info(model),
        view_connection_urls(model),
        view_secret_card(model, 1),
        view_secret_card(model, 2),
        view_delete_section(model),
      ])
  }
}

fn view_copy_state(state: CopyState) -> Element(Msg) {
  case state {
    CopyIdle -> element.none()
    CopySuccess(message) ->
      div(
        [
          class("alert alert-success"),
          attribute.role("status"),
          attribute.aria_live("polite"),
        ],
        [span([class("alert-message")], [text(message)])],
      )
    CopyError(message) ->
      div([class("alert alert-error"), attribute.role("alert")], [
        span([class("alert-message")], [text(message)]),
      ])
  }
}

fn view_info(model: Model) -> Element(Msg) {
  div([class("card")], [
    h2([], [text("Tenant Information")]),
    div([class("detail-row")], [
      span([class("detail-label")], [text("ID")]),
      div([class("detail-value-with-action")], [
        code([class("detail-value")], [text(model.tenant_id)]),
        button(
          [class("btn btn-secondary btn-sm"), event.on_click(CopyTenantId)],
          [text("Copy ID")],
        ),
      ]),
    ]),
    div([class("detail-row")], [
      span([class("detail-label")], [text("Name")]),
      span([class("detail-value")], [text(model.tenant_name)]),
    ]),
    div([class("detail-row")], [
      span([class("detail-label")], [text("Documents")]),
      a(
        [
          class("btn btn-secondary btn-sm"),
          attribute.href("/admin/tenants/" <> model.tenant_id <> "/documents"),
        ],
        [
          text(case model.document_count {
            Some(count) -> "View Documents (" <> int.to_string(count) <> ")"
            None -> "View Documents"
          }),
        ],
      ),
    ]),
  ])
}

fn derive_socket_url(http_url: String) -> String {
  case string.starts_with(http_url, "https://") {
    True -> "wss://" <> string.drop_start(http_url, 8) <> "/socket"
    False ->
      case string.starts_with(http_url, "http://") {
        True -> "ws://" <> string.drop_start(http_url, 7) <> "/socket"
        False -> "ws://" <> http_url <> "/socket"
      }
  }
}

fn view_connection_urls(model: Model) -> Element(Msg) {
  let origin = api.get_origin()
  let socket_url = derive_socket_url(origin)
  let token_mint_url =
    origin <> "/api/tenants/" <> model.tenant_id <> "/token-mint"

  div([class("card")], [
    h2([], [text("Connection URLs")]),
    p([class("form-help")], [
      text("Use these URLs to connect client applications to this tenant."),
    ]),
    div([class("detail-row")], [
      span([class("detail-label")], [text("HTTP URL")]),
      code([class("detail-value")], [text(origin)]),
    ]),
    div([class("detail-row")], [
      span([class("detail-label")], [text("WebSocket URL")]),
      code([class("detail-value")], [text(socket_url)]),
    ]),
    div([class("detail-row")], [
      span([class("detail-label")], [text("Token Mint")]),
      code([class("detail-value")], [text(token_mint_url)]),
    ]),
    div([class("detail-row")], [
      span([class("detail-label")], [text("Client Config")]),
      html.pre([class("code-block")], [
        code([], [
          text(
            "import { FloodgateClient } from \"@tylerbu/floodgate-client\";\n\n"
            <> "const client = new FloodgateClient({\n"
            <> "  connection: {\n"
            <> "    httpUrl: \""
            <> origin
            <> "\",\n"
            <> "    socketUrl: \""
            <> socket_url
            <> "\",\n"
            <> "    tenantId: \""
            <> model.tenant_id
            <> "\",\n"
            <> "    tokenProvider,\n"
            <> "    user,\n"
            <> "  }\n"
            <> "});",
          ),
        ]),
      ]),
    ]),
  ])
}

fn view_secret_card(model: Model, slot: Int) -> Element(Msg) {
  let #(slot_state, secret_value, is_visible) = case slot {
    1 -> #(model.secret1_state, model.secret1_value, model.secret1_visible)
    _ -> #(model.secret2_state, model.secret2_value, model.secret2_visible)
  }

  let toggle_msg = case slot {
    1 -> ToggleSecret1Visible
    _ -> ToggleSecret2Visible
  }

  div([class("card")], [
    h2([], [text("Secret " <> int.to_string(slot))]),
    view_slot_status(slot_state),
    case string.is_empty(secret_value) {
      True ->
        p([class("form-help")], [
          text("Secret value is hidden. Regenerate to see the new value."),
        ])
      False ->
        div([class("secret-display")], [
          code([class("secret-value")], [
            text(case is_visible {
              True -> secret_value
              False -> "••••••••••••••••••••••••••••••••"
            }),
          ]),
          button(
            [class("btn btn-secondary btn-sm"), event.on_click(toggle_msg)],
            [
              text(case is_visible {
                True -> "Hide"
                False -> "Show"
              }),
            ],
          ),
          button(
            [
              class("btn btn-secondary btn-sm"),
              event.on_click(CopySecret(slot)),
            ],
            [text("Copy")],
          ),
        ])
    },
    view_regenerate_section(slot, slot_state),
  ])
}

fn view_slot_status(state: SecretSlotState) -> Element(Msg) {
  case state {
    SlotSuccess(message) ->
      div(
        [
          class("alert alert-success"),
          attribute.role("status"),
          attribute.aria_live("polite"),
        ],
        [
          span([class("alert-message")], [text(message)]),
        ],
      )
    SlotError(message) ->
      div(
        [
          class("alert alert-error"),
          attribute.role("alert"),
          attribute.aria_live("assertive"),
        ],
        [
          span([class("alert-icon")], [text("!")]),
          span([class("alert-message")], [text(message)]),
        ],
      )
    _ -> element.none()
  }
}

fn view_regenerate_section(slot: Int, state: SecretSlotState) -> Element(Msg) {
  case state {
    SlotConfirming(confirmation) -> {
      let matches = confirmation == "REGENERATE"
      div([class("regenerate-confirm")], [
        p([class("delete-warning")], [
          text(
            "Rotating this secret immediately invalidates every token signed with it.",
          ),
        ]),
        div([class("form-group")], [
          html.label(
            [attribute.for("regenerate-confirm-" <> int.to_string(slot))],
            [text("Type REGENERATE to continue")],
          ),
          html.input([
            type_("text"),
            attribute.id("regenerate-confirm-" <> int.to_string(slot)),
            attribute.value(confirmation),
            attribute.autocomplete("off"),
            event.on_input(fn(input) {
              UpdateRegenerateConfirmation(slot, input)
            }),
          ]),
        ]),
        div([class("delete-actions")], [
          button(
            [
              class("btn btn-danger"),
              disabled(!matches),
              event.on_click(ConfirmRegenerate(slot)),
            ],
            [text("Rotate Secret " <> int.to_string(slot))],
          ),
          button(
            [class("btn btn-secondary"), event.on_click(CancelRegenerate(slot))],
            [text("Cancel")],
          ),
        ]),
      ])
    }

    SlotSubmitting ->
      p([class("loading"), attribute.role("status")], [
        text("Rotating secret..."),
      ])

    _ ->
      button(
        [class("btn btn-primary"), event.on_click(RequestRegenerate(slot))],
        [text("Rotate Secret " <> int.to_string(slot))],
      )
  }
}

fn view_delete_section(model: Model) -> Element(Msg) {
  div([class("card danger-card")], [
    h2([], [text("Danger Zone")]),
    case model.delete_state {
      DeleteHidden ->
        button([class("btn btn-danger"), event.on_click(ShowDeleteConfirm)], [
          text("Delete Tenant"),
        ])

      DeleteConfirming(confirmation) -> {
        let matches = confirmation == model.tenant_id
        div([class("delete-confirm")], [
          p([class("delete-warning")], [
            text(
              "This removes the tenant registration and secrets. Stored documents are not deleted.",
            ),
          ]),
          div([class("delete-id-row")], [
            p([class("delete-tenant-id")], [text(model.tenant_id)]),
            button(
              [class("btn btn-secondary btn-sm"), event.on_click(CopyTenantId)],
              [text("Copy ID")],
            ),
          ]),
          div([class("form-group")], [
            html.label([attribute.for("delete-confirmation")], [
              text("Type the tenant ID to confirm"),
            ]),
            html.input([
              type_("text"),
              attribute.id("delete-confirmation"),
              attribute.placeholder("Type tenant ID to confirm"),
              attribute.value(confirmation),
              event.on_input(UpdateDeleteConfirmation),
              class("delete-confirm-input"),
            ]),
          ]),
          div([class("delete-actions")], [
            button(
              [
                class("btn btn-danger"),
                disabled(!matches),
                event.on_click(ConfirmDelete),
              ],
              [text("Delete Tenant")],
            ),
            button(
              [class("btn btn-secondary"), event.on_click(HideDeleteConfirm)],
              [text("Cancel")],
            ),
          ]),
        ])
      }

      DeleteSubmitting ->
        p([class("loading"), attribute.role("status")], [
          text("Deleting tenant..."),
        ])

      DeleteError(message) ->
        div([], [
          div([class("alert alert-error"), attribute.role("alert")], [
            span([class("alert-icon")], [text("!")]),
            span([class("alert-message")], [text(message)]),
          ]),
          button(
            [class("btn btn-secondary"), event.on_click(HideDeleteConfirm)],
            [text("Cancel")],
          ),
        ])
    },
  ])
}
