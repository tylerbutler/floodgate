//// ETS-backed durable store for ops + latest summary, keyed by document topic.
//// Survives session-actor restarts within a VM run. Analogue of levee_storage.

@external(erlang, "floodgate_store_ffi", "open")
pub fn open() -> Nil

@external(erlang, "floodgate_store_ffi", "put_op")
pub fn put_op(topic: String, sn: Int, contents: String) -> Nil

@external(erlang, "floodgate_store_ffi", "get_ops")
pub fn get_ops(topic: String) -> List(#(Int, String))

@external(erlang, "floodgate_store_ffi", "put_summary")
pub fn put_summary(topic: String, handle: String, sn: Int) -> Nil

@external(erlang, "floodgate_store_ffi", "get_summary")
pub fn get_summary(topic: String) -> #(String, Int)

@external(erlang, "floodgate_store_ffi", "put_obj")
pub fn put_obj(tenant: String, sha: String, data: String) -> Nil

@external(erlang, "floodgate_store_ffi", "get_obj")
pub fn get_obj(tenant: String, sha: String) -> Result(String, Nil)
