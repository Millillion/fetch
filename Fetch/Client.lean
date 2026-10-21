/-
Copyright (c) 2026 Millillion. Released under the MIT license.
-/
import Fetch.Transports

/-! `fetch` and the response accessors. -/

namespace Fetch
open Std.Http Std.Async

private def statusOf (code : UInt16) (text : String) : Status :=
  match Status.ofCode none code with
  | some status => status
  | none => match CustomStatus.ofCodeAndPhrase? code text with
    | some custom => .other custom
    | none => .other default

private def headersOf (pairs : Array (String × String)) : Headers :=
  pairs.foldl (init := .empty) fun headers (name, value) =>
    match Header.Name.ofString? name, Header.Value.ofString? value with
    | some name, some value => headers.insert name value
    | _, _ => headers

/--
Perform an HTTP request, like the web platform's `fetch`.

Returns once the response's status and headers have arrived; read the body with
`Response.text`, `Response.bytes`, `Response.json` or as a stream (`response.body.stream`).
HTTP error statuses (404, 500, ...) are responses, not errors: check `Response.ok`.
Network failures, timeouts and refused redirects (`redirect := .error`) throw.
-/
def fetch (url : String) (options : Options := {}) : Async Response := do
  let transport ← match options.transport with
    | some transport => pure transport
    | none => selectTransport options.backend
  let request : Request := {
    url, method := toString options.method,
    headers := options.headers.toArray.map fun (name, value) => (toString name, toString value),
    body := options.body, redirect := options.redirect, timeoutMs := options.timeout }
  let exchange ← blocking (transport.start request)
  if options.redirect == .error && isRedirectStatus exchange.head.status then
    blocking exchange.close
    throw (IO.userError s!"fetch: {url} redirected ({exchange.head.status}) and redirect := .error")
  let stream ← Std.Http.Body.stream fun stream => do
    try
      repeat
        match ← blocking exchange.read with
        | some chunk => if !chunk.isEmpty then stream.send (Chunk.ofByteArray chunk)
        | none => break
    finally
      blocking exchange.close
  let head := exchange.head
  return {
    line := { status := statusOf head.status head.statusText, version := .v11, headers := headersOf head.headers }
    body := { stream, statusText := head.statusText, url := head.url, redirected := head.redirected,
              transport := transport.name } }

namespace Response

/-- The numeric status code, for example `200`. -/
def status (response : Response) : UInt16 := response.line.status.toCode

/-- Whether the status is in the range 200–299. -/
def ok (response : Response) : Bool := 200 ≤ response.status && response.status ≤ 299

/-- The reason phrase the server sent (empty for HTTP/2). -/
def statusText (response : Response) : String := response.body.statusText

/-- The URL of the final response, after redirects. -/
def url (response : Response) : String := response.body.url

/-- Whether redirects were followed to reach this response. -/
def redirected (response : Response) : Bool := response.body.redirected

/-- Which transport performed the request (`node`, `libcurl`, `curl` or a custom name). -/
def transport (response : Response) : String := response.body.transport

/-- The response headers (names in lower case). -/
def headers (response : Response) : Headers := response.line.headers

/-- The last value of a header, by case-insensitive name. -/
def header? (response : Response) (name : String) : Option String :=
  (Header.Name.ofString? (name.map Char.toLower)).bind fun name => (response.headers.getLast? name).map toString

/-- Read the whole body. -/
def bytes (response : Response) : Async ByteArray := do
  let mut result := ByteArray.empty
  repeat
    match ← response.body.stream.recv with
    | some chunk => result := result ++ chunk.data
    | none => break
  return result

/-- Read the whole body as UTF-8 text (invalid UTF-8 is an error). -/
def text (response : Response) : Async String := do
  let data ← response.bytes
  match String.fromUTF8? data with
  | some text => return text
  | none => throw (IO.userError "fetch: the response body is not valid UTF-8")

/-- Read the whole body as JSON. -/
def json (response : Response) : Async Lean.Json := do
  match Lean.Json.parse (← response.text) with
  | .ok json => return json
  | .error message => throw (IO.userError s!"fetch: the response body is not JSON: {message}")

/-- Stop reading the body and release the connection. -/
def close (response : Response) : Async Unit := response.body.stream.close

end Response
end Fetch
