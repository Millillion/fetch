/-
Copyright (c) 2026 Millillion. Released under the MIT license.
-/
import Fetch.Basic

/-! Bindings to `c/fetch_shim.c`. -/

namespace Fetch.Shim

/-- `1` when compiled by Lasm for Node.js (Node `fetch`), `0` natively. -/
@[extern "fetch_shim_backend"] opaque backend : Unit → UInt8

private opaque NodeBodyPointed : NonemptyType
/-- A response body held by the Node host; closing it cancels the stream. -/
def NodeBody : Type := NodeBodyPointed.type
instance : Nonempty NodeBody := NodeBodyPointed.property

/-- Start a request with Node's `fetch`: the request as JSON, then the body bytes. Returns the head as JSON. -/
@[extern "fetch_shim_node_start"] opaque nodeStart (request : @& String) (body : @& ByteArray) : IO String
@[extern "fetch_shim_node_adopt"] opaque nodeAdopt (handle : UInt32) : IO NodeBody
@[extern "fetch_shim_node_read"] opaque nodeRead (body : @& NodeBody) : IO (Option ByteArray)
@[extern "fetch_shim_node_close"] opaque nodeClose (body : @& NodeBody) : IO Unit

private opaque CurlBodyPointed : NonemptyType
/-- A libcurl transfer; closing it stops the transfer. -/
def CurlBody : Type := CurlBodyPointed.type
instance : Nonempty CurlBody := CurlBodyPointed.property

/-- Whether libcurl could be loaded (tried once). -/
@[extern "fetch_shim_curl_available"] opaque curlAvailable : IO Bool
@[extern "fetch_shim_curl_start"] opaque curlStart (url method : @& String) (headers : @& Array String) (body : @& ByteArray)
  (hasBody follow : Bool) (timeoutMs : UInt64) : IO CurlBody
/-- Status, effective URL, redirect count and the final response's raw header lines. -/
@[extern "fetch_shim_curl_head"] opaque curlHead (body : @& CurlBody) : IO (UInt32 × String × UInt32 × String)
@[extern "fetch_shim_curl_read"] opaque curlRead (body : @& CurlBody) : IO (Option ByteArray)
@[extern "fetch_shim_curl_close"] opaque curlClose (body : @& CurlBody) : IO Unit

end Fetch.Shim
