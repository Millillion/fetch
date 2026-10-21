/-
Copyright (c) 2026 Millillion. Released under the MIT license.
-/
import Fetch

/-!
Tests for `Fetch`, run natively and under Lasm (Node.js):
  FetchTest BASE_URL [--online] [--backend auto|node|libcurl|curl]...
`BASE_URL` is the local test server (`node tests/server.mjs`). Each backend runs
the same cases; a backend that is unavailable on this system is reported and skipped.
-/

open Fetch Std.Async

namespace FetchTests

structure Outcome where
  passed : Nat := 0
  failed : Nat := 0

def check (name : String) (condition : Bool) (detail : String := "") : StateT Outcome IO Unit := do
  if condition then
    modify fun o => { o with passed := o.passed + 1 }
    IO.println s!"  ok   {name}"
  else
    modify fun o => { o with failed := o.failed + 1 }
    IO.println s!"  FAIL {name}{if detail.isEmpty then "" else ": " ++ detail}"

def run (action : Async α) : IO (Except IO.Error α) := action.block.toBaseIO

def suite (base : String) (backend : Backend) (online : Bool) : StateT Outcome IO Unit := do
  let opts : Options := { backend }
  -- Plain GET.
  match ← run (do let r ← fetch s!"{base}/text" opts; return (r, ← r.text)) with
  | .ok (r, text) =>
    check "GET text" (r.ok && r.status == 200 && text == "hello, fetch") s!"{r.status} {text}"
    check "headers" ((r.header? "Content-Type").map (·.startsWith "text/plain") == some true && r.header? "x-served-by" == some "fetch-tests")
      s!"{r.header? "content-type"}"
    check "not redirected" (!r.redirected && r.url == s!"{base}/text") r.url
    IO.println s!"  transport: {r.transport}"
  | .error e => check "GET text" false (toString e)
  -- JSON.
  match ← run (do let r ← fetch s!"{base}/json" opts; r.json) with
  | .ok json => check "json" ((json.getObjValAs? Nat "lean").toOption == some 4) json.compress
  | .error e => check "json" false (toString e)
  -- POST with a body and a header.
  match ← run (do
      let r ← fetch s!"{base}/echo" ((({ opts with method := .post } : Options).header "x-test" "yes").text "payload ✓")
      r.json) with
  | .ok json => check "POST body and header" (json.compress == "{\"body\":\"payload ✓\",\"method\":\"POST\",\"test\":\"yes\",\"type\":null}") json.compress
  | .error e => check "POST body and header" false (toString e)
  -- PUT with JSON.
  match ← run (do let r ← fetch s!"{base}/echo" (({ opts with method := .put } : Options).json (Lean.Json.mkObj [("n", 1)])); r.json) with
  | .ok json => check "PUT json" ((json.getObjValAs? String "body").toOption == some "{\"n\":1}" &&
      (json.getObjValAs? String "type").toOption == some "application/json") json.compress
  | .error e => check "PUT json" false (toString e)
  -- Redirects.
  match ← run (do let r ← fetch s!"{base}/redirect-chain" opts; return (r, ← r.text)) with
  | .ok (r, text) => check "redirect follow" (r.redirected && r.url == s!"{base}/text" && text == "hello, fetch") s!"{r.url} {r.redirected} {text}"
  | .error e => check "redirect follow" false (toString e)
  match ← run (do let r ← fetch s!"{base}/redirect" { opts with redirect := .manual }; return (r.status, r.header? "location")) with
  | .ok (status, location) => check "redirect manual" (status == 302 && location == some "/text") s!"{status} {location}"
  | .error e => check "redirect manual" false (toString e)
  match ← run (fetch s!"{base}/redirect" { opts with redirect := .error }) with
  | .ok r => check "redirect error" false s!"status {r.status}"
  | .error _ => check "redirect error" true
  -- HTTP errors are responses.
  match ← run (do let r ← fetch s!"{base}/missing" opts; return (r, ← r.text)) with
  | .ok (r, text) => check "404 response" (!r.ok && r.status == 404 && text == "missing") s!"{r.status}"
  | .error e => check "404 response" false (toString e)
  -- Streaming body.
  match ← run (do
      let r ← fetch s!"{base}/stream" opts
      let mut parts := #[]
      repeat
        match ← r.body.stream.recv with
        | some chunk => parts := parts.push chunk.data
        | none => break
      return parts) with
  | .ok parts =>
    let text := String.fromUTF8! (parts.foldl (· ++ ·) .empty)
    check "streaming body" (text == "chunk-1\nchunk-2\nchunk-3\n" && parts.size ≥ 1) s!"{parts.size} parts"
  | .error e => check "streaming body" false (toString e)
  -- Binary and large bodies.
  match ← run (do let r ← fetch s!"{base}/bytes" opts; r.bytes) with
  | .ok data => check "binary body" (data.size == 256 && data.get! 0 == 0 && data.get! 255 == 255) s!"{data.size}"
  | .error e => check "binary body" false (toString e)
  match ← run (do let r ← fetch s!"{base}/large" opts; r.bytes) with
  | .ok data => check "1 MiB body" (data.size == 1048576) s!"{data.size}"
  | .error e => check "1 MiB body" false (toString e)
  match ← run (do let r ← fetch s!"{base}/gzip" opts; r.text) with
  | .ok text => check "gzip decoded" (text == "compressed hello") text
  | .error e => check "gzip decoded" false (toString e)
  -- HEAD.
  match ← run (do let r ← fetch s!"{base}/text" { opts with method := .head }; return (r.status, ← r.bytes)) with
  | .ok (status, data) => check "HEAD" (status == 200 && data.isEmpty) s!"{status} {data.size}"
  | .error e => check "HEAD" false (toString e)
  -- Timeout and connection failure throw.
  match ← run (fetch s!"{base}/slow" { opts with timeout := some 500 } >>= (·.text)) with
  | .ok text => check "timeout" false text
  | .error _ => check "timeout" true
  match ← run (fetch "http://127.0.0.1:1/" opts) with
  | .ok r => check "connection refused" false s!"{r.status}"
  | .error _ => check "connection refused" true
  if online then
    match ← run (do let r ← fetch "https://example.com/" opts; return (r.status, ← r.text)) with
    | .ok (status, text) => check "HTTPS example.com" (status == 200 && (text.splitOn "Example Domain").length > 1) s!"{status}"
    | .error e => check "HTTPS example.com" false (toString e)

def available : Backend → IO Bool
  | .node => return Fetch.Shim.backend () == 1
  | .libcurl => return Fetch.Shim.backend () == 0 && (← Fetch.Shim.curlAvailable)
  | .curl => do
    try return (← IO.Process.output { cmd := "curl", args := #["--version"] }).exitCode == 0
    catch _ => return false
  | .auto => return true

/-- Run the suite: `BASE_URL [--online] [--backend NAME]...`. -/
def main (args : List String) : IO UInt32 := do
  let base :: rest := args | IO.eprintln "usage: FetchTest BASE_URL [--online] [--backend NAME]..."; return 2
  let online := rest.contains "--online"
  let named := (rest.zip (rest.drop 1)).filterMap fun (flag, value) => if flag == "--backend" then some value else none
  let backends := if named.isEmpty then [Backend.auto, .node, .libcurl, .curl] else named.filterMap fun
    | "auto" => some .auto | "node" => some .node | "libcurl" => some .libcurl | "curl" => some .curl | _ => none
  let mut outcome : Outcome := {}
  -- The pattern most Lean programs use today: run the curl tool directly.
  if ← available .curl then
    let out ← IO.Process.output { cmd := "curl", args := #["-s", s!"{base}/text"] }
    IO.println s!"curl subprocess: {if out.exitCode == 0 && out.stdout == "hello, fetch" then "ok" else "FAIL"}"
    if !(out.exitCode == 0 && out.stdout == "hello, fetch") then outcome := { outcome with failed := outcome.failed + 1 }
  for backend in backends do
    if !(← available backend) then
      IO.println s!"{repr backend}: not available here, skipped"
      continue
    IO.println s!"{repr backend}:"
    let ((), next) ← (suite base backend online).run outcome
    outcome := next
  IO.println s!"{outcome.passed} passed, {outcome.failed} failed"
  return if outcome.failed == 0 then 0 else 1

end FetchTests
