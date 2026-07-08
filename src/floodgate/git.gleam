//// Content-addressed git object storage (blobs/trees/commits), SHA1-keyed,
//// matching levee's GitController: POST stores body -> {sha}, GET returns it.
//// Analogue of levee_storage git backend.

import gleam/bit_array
import gleam/crypto
import floodgate/store

/// Store an object's raw body, returning its SHA1 (git-style id).
pub fn create(tenant: String, body: String) -> String {
  let sha = sha1(body)
  store.put_obj(tenant, sha, body)
  sha
}

/// Fetch an object's raw body by SHA.
pub fn fetch(tenant: String, sha: String) -> Result(String, Nil) {
  store.get_obj(tenant, sha)
}

fn sha1(body: String) -> String {
  crypto.hash(crypto.Sha1, bit_array.from_string(body))
  |> bit_array.base64_url_encode(False)
}
