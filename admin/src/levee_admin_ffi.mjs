import { Some, None } from "../gleam_stdlib/gleam/option.mjs";

export function get_query_param(name) {
  const params = new URLSearchParams(window.location.search);
  const value = params.get(name);
  if (value) {
    return new Some(value);
  }
  return new None();
}

export function navigate_to(url) {
  window.location.href = url;
}

export function get_origin() {
  return window.location.origin;
}

export function get_current_path() {
  return window.location.pathname;
}
