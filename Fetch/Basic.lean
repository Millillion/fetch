/-
Copyright (c) 2026 Millillion. Released under the MIT license.
-/
import Std.Http
import Std.Async
import Lean.Data.Json

/-!
# Fetch: request options, transports and responses

`Fetch` is a fetch-style HTTP client. Requests and responses use the `Std.Http`
types (methods, headers, statuses, `Std.Http.Response`), and the response body is a
`Std.Http.Body.Stream` that is read as it arrives.

Requests go through a `Transport`. Three are built in and chosen automatically:

* `node`: under [Lasm](https://github.com/Millillion/lasm) (Lean compiled to
  WebAssembly for Node.js), Node's global `fetch`;
* `libcurl`: natively, libcurl loaded at run time (no build-time dependency);
* `curl`: natively, the `curl` command-line tool, when libcurl cannot be loaded.
-/

namespace Fetch

open Std.Async

/-- What to do when the server answers with a redirect (as in the web platform's `fetch`). -/
inductive Redirect where
  /-- Follow redirects (up to 20). -/
  | follow
  /-- Fail with an error when the server redirects. -/
  | error
  /-- Return the redirect response itself. -/
  | manual
  deriving Repr, BEq, Inhabited

def Redirect.toString : Redirect → String
  | .follow => "follow" | .error => "error" | .manual => "manual"

/-- Which transport to use. `auto` picks `node` under Lasm, else `libcurl`, else `curl`. -/
inductive Backend where
  | auto | node | libcurl | curl
  deriving Repr, BEq, Inhabited

/-- A request as a transport sees it. Header names are as given; values are strings. -/
structure Request where
  url : String
  method : String := "GET"
  headers : Array (String × String) := #[]
  body : Option ByteArray := none
  redirect : Redirect := .follow
  /-- Milliseconds for the whole exchange, including reading the body. -/
  timeoutMs : Option Nat := none

/-- Status line and headers of the response a transport received. -/
structure Head where
  status : UInt16
  statusText : String := ""
  /-- The URL of the final response, after redirects. -/
  url : String
  redirected : Bool := false
  /-- Header names are lower case, as in the web platform's `Headers`. -/
  headers : Array (String × String) := #[]

/-- A response in progress: its head, and its body read chunk by chunk. -/
structure Exchange where
  head : Head
  /-- The next chunk of the body, or `none` at its end. Blocks until data arrives. -/
  read : IO (Option ByteArray)
  /-- Stop receiving and release the connection. -/
  close : IO Unit

/-- A way to perform HTTP requests. `start` returns once the response head has arrived. -/
structure Transport where
  name : String
  start : Request → IO Exchange

/-- Options for `fetch`, modeled on the web platform's `RequestInit`. -/
structure Options where
  method : Std.Http.Method := .get
  headers : Std.Http.Headers := .empty
  body : Option ByteArray := none
  redirect : Redirect := .follow
  /-- Milliseconds for the whole exchange, including reading the body. `none` waits indefinitely. -/
  timeout : Option Nat := none
  backend : Backend := .auto
  /-- A custom transport, used instead of `backend`. -/
  transport : Option Transport := none

/-- Add a header to the options (`Std.Http.Headers.insert!`: panics on an invalid name or value). -/
def Options.header (options : Options) (name value : String) : Options :=
  { options with headers := options.headers.insert! name value }

/-- Use a UTF-8 string as the request body. -/
def Options.text (options : Options) (body : String) : Options :=
  { options with body := some body.toUTF8 }

/-- Use JSON as the request body and set `content-type: application/json`. -/
def Options.json (options : Options) (body : Lean.Json) : Options :=
  ({ options with body := some body.compress.toUTF8 }).header "content-type" "application/json"

/-- The response body: the stream, and what the transport reported about the exchange. -/
structure Body where
  stream : Std.Http.Body.Stream
  statusText : String
  url : String
  redirected : Bool
  transport : String

instance : Std.Http.Body Body where
  recv body := body.stream.recv
  close body := body.stream.close
  isClosed body := body.stream.isClosed
  recvSelector body := body.stream.recvSelector
  tryRecv body := body.stream.tryRecvBody
  getKnownSize body := body.stream.getKnownSize
  setKnownSize body := body.stream.setKnownSize

/-- What `fetch` returns: a `Std.Http.Response` whose body streams from the network. -/
abbrev Response := Std.Http.Response Body

/-- Run a blocking action on a dedicated thread, as an `Async` computation. -/
def blocking (action : IO α) : Async α := do
  let result ← Async.ofIOTask (IO.asTask action Task.Priority.dedicated)
  Async.ofExcept result

end Fetch
