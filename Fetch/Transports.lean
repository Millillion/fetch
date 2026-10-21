/-
Copyright (c) 2026 Millillion. Released under the MIT license.
-/
import Fetch.Shim

/-! The built-in transports: Node's `fetch` (Lasm), libcurl and the `curl` tool. -/

namespace Fetch
open Lean

private def trimmed (s : String) : String := s.trimAscii.copy
private def trimmedEnd (s : String) : String := s.trimAsciiEnd.copy

/-- Lower-case ASCII header names, as the web platform's `Headers` reports them. -/
def lowerName (name : String) : String := name.map Char.toLower

/-- Parse raw HTTP header lines (`Name: value`), skipping status lines. -/
def parseHeaderLines (text : String) : Array (String × String) := Id.run do
  let mut headers := #[]
  for line in text.splitOn "\n" do
    let line := trimmedEnd line
    if line.isEmpty || line.startsWith "HTTP/" then continue
    match line.splitOn ":" with
    | name :: rest@(_ :: _) => headers := headers.push (lowerName (trimmed name), trimmed (":".intercalate rest))
    | _ => pure ()
  return headers

/-- The reason phrase of a status line such as `HTTP/1.1 404 Not Found`. -/
def statusLineText (line : String) : String :=
  match (trimmedEnd line).splitOn " " with
  | _ :: _ :: phrase => " ".intercalate phrase
  | _ => ""

/-- Resolve a `Location` header against the URL that answered with it. -/
def resolveLocation (base location : String) : String :=
  if location.startsWith "http://" || location.startsWith "https://" then location
  else
    let scheme := (base.splitOn "://").headD "https"
    let afterScheme := (base.splitOn "://").getD 1 base
    let authority := (afterScheme.splitOn "/").headD ""
    if location.startsWith "//" then s!"{scheme}:{location}"
    else if location.startsWith "/" then s!"{scheme}://{authority}{location}"
    else
      let path := (base.splitOn "?").headD base
      let parts := path.splitOn "/"
      "/".intercalate (parts.dropLast ++ [location])

/-- curl sends `application/x-www-form-urlencoded` for a body unless told otherwise;
`fetch` sends no content type for raw bytes. `Name:` removes a curl default header. -/
def curlDefaultsRemoved (request : Request) : Array String :=
  if request.body.isSome && !request.headers.any (lowerName ·.1 == "content-type") then #["Content-Type:"] else #[]

def isRedirectStatus (status : UInt16) : Bool :=
  status == 301 || status == 302 || status == 303 || status == 307 || status == 308

/-- Node's `fetch`, available when the program is compiled by Lasm for Node.js. -/
def nodeTransport : Transport where
  name := "node"
  start request := do
    let headers := request.headers.map fun (name, value) => Json.arr #[Json.str name, Json.str value]
    let json := Json.mkObj [("url", Json.str request.url), ("method", Json.str request.method),
      ("headers", Json.arr headers), ("redirect", Json.str request.redirect.toString),
      ("hasBody", Json.bool request.body.isSome), ("timeoutMs", toJson (request.timeoutMs.getD 0))]
    let headJson ← Shim.nodeStart json.compress (request.body.getD .empty)
    let head ← IO.ofExcept (Json.parse headJson)
    let handle : Nat ← IO.ofExcept (head.getObjValAs? Nat "handle")
    let body ← Shim.nodeAdopt handle.toUInt32
    let status : Nat ← IO.ofExcept (head.getObjValAs? Nat "status")
    let pairs : Array (Array String) ← IO.ofExcept (head.getObjValAs? (Array (Array String)) "headers")
    return {
      head := { status := status.toUInt16, statusText := (head.getObjValAs? String "statusText").toOption.getD "",
                url := (head.getObjValAs? String "url").toOption.getD request.url,
                redirected := (head.getObjValAs? Bool "redirected").toOption.getD false,
                headers := pairs.filterMap fun pair => match pair with
                  | #[name, value] => some (lowerName name, value) | _ => none }
      read := Shim.nodeRead body
      close := Shim.nodeClose body }

/-- libcurl, loaded at run time. -/
def libcurlTransport : Transport where
  name := "libcurl"
  start request := do
    let headers := request.headers.map (fun (name, value) => if value.isEmpty then s!"{name};" else s!"{name}: {value}")
      ++ curlDefaultsRemoved request
    let transfer ← Shim.curlStart request.url request.method headers (request.body.getD .empty)
      request.body.isSome (request.redirect == .follow) (request.timeoutMs.getD 0).toUInt64
    let (status, url, redirects, raw) ← Shim.curlHead transfer
    let statusLine := ((raw.splitOn "\n").find? (·.startsWith "HTTP/")).getD ""
    return {
      head := { status := status.toUInt16, statusText := statusLineText statusLine,
                url := if url.isEmpty then request.url else url, redirected := redirects > 0,
                headers := parseHeaderLines raw }
      read := Shim.curlRead transfer
      close := Shim.curlClose transfer }

/-- Read from a pipe until `buffer` contains a complete header block; returns the block and the rest. -/
private partial def readHeaderBlock (stdout : IO.FS.Handle) (buffer : ByteArray) : IO (Option (String × ByteArray)) := do
  -- Find "\r\n\r\n" (or "\n\n") in the raw bytes.
  let rec find (i : Nat) : Option (Nat × Nat) :=
    if i + 1 < buffer.size then
      if buffer.get! i == 10 && buffer.get! (i + 1) == 10 then some (i, 2)
      else if i + 3 < buffer.size && buffer.get! i == 13 && buffer.get! (i + 1) == 10 && buffer.get! (i + 2) == 13
        && buffer.get! (i + 3) == 10 then some (i, 4)
      else find (i + 1)
    else none
  match find 0 with
  | some (position, length) =>
    return some ((String.fromUTF8? (buffer.extract 0 position)).getD "", buffer.extract (position + length) buffer.size)
  | none =>
    let more ← stdout.read 65536
    if more.isEmpty then return none
    readHeaderBlock stdout (buffer ++ more)

/-- The `curl` command-line tool (the de facto standard for HTTP in Lean programs). -/
def curlToolTransport : Transport where
  name := "curl"
  start request := do
    let head := request.method == "HEAD"
    let mut args := #["--silent", "--show-error", "--compressed", "--no-buffer", "-H", "Expect:"]
    args := args ++ (if head then #["--head"] else #["--dump-header", "-"])
    if !head && request.method != "GET" || request.body.isSome then args := args ++ #["-X", request.method]
    for (name, value) in request.headers do
      args := args ++ #["-H", if value.isEmpty then s!"{name};" else s!"{name}: {value}"]
    for header in curlDefaultsRemoved request do args := args ++ #["-H", header]
    if request.body.isSome then args := args ++ #["--data-binary", "@-"]
    if request.redirect == .follow then args := args ++ #["--location", "--max-redirs", "20"]
    if let some ms := request.timeoutMs then
      args := args ++ #["--max-time", s!"{ms / 1000}.{((ms % 1000 + 1000).repr.drop 1).copy}"]
    args := args.push request.url
    let child ← IO.Process.spawn { cmd := "curl", args, stdin := .piped, stdout := .piped, stderr := .piped }
    let (stdin, child) ← child.takeStdin
    if let some body := request.body then stdin.write body
    stdin.flush
    let stderrTask ← IO.asTask child.stderr.readToEnd Task.Priority.dedicated
    let failure : IO String := do
      let _ ← child.wait
      let message := match stderrTask.get with | .ok text => trimmed text | .error _ => ""
      return if message.isEmpty then "curl failed" else message
    -- Header blocks: interim (1xx) responses and followed redirects come first.
    let mut buffer := ByteArray.empty
    let mut url := request.url
    let mut redirected := false
    let mut final : Option (String × ByteArray) := none
    repeat
      match ← readHeaderBlock child.stdout buffer with
      | none => throw (IO.userError (← failure))
      | some (block, rest) =>
        let statusLine := trimmedEnd ((block.splitOn "\n").headD "")
        let status := ((statusLine.splitOn " ").getD 1 "0").toNat!
        let headers := parseHeaderLines block
        let location := (headers.find? (·.1 == "location")).map (·.2)
        if status < 200 && status ≠ 101 then buffer := rest; continue
        if request.redirect == .follow && isRedirectStatus status.toUInt16 && location.isSome then
          url := resolveLocation url location.get!; redirected := true; buffer := rest; continue
        final := some (block, rest)
        break
    let some (block, rest) := final | throw (IO.userError (← failure))
    let statusLine := trimmedEnd ((block.splitOn "\n").headD "")
    let pending ← IO.mkRef (some rest)
    let finished ← IO.mkRef false
    return {
      head := { status := ((statusLine.splitOn " ").getD 1 "0").toNat!.toUInt16, statusText := statusLineText statusLine,
                url, redirected, headers := parseHeaderLines block }
      read := do
        if let some first ← pending.modifyGet (fun p => (p, none)) then
          if !first.isEmpty then return some first
        if ← finished.get then return none
        let chunk ← child.stdout.read 65536
        if !chunk.isEmpty then return some chunk
        finished.set true
        let code ← child.wait
        if code != 0 then throw (IO.userError (← failure))
        return none
      close := do
        unless ← finished.get do
          finished.set true
          child.kill
          discard <| child.wait }

/-- The transport `backend` selects; `auto` prefers Node, then libcurl, then the curl tool. -/
def selectTransport : Backend → IO Transport
  | .node => return nodeTransport
  | .libcurl => return libcurlTransport
  | .curl => return curlToolTransport
  | .auto => do
    if Shim.backend () == 1 then return nodeTransport
    if ← Shim.curlAvailable then return libcurlTransport
    return curlToolTransport

end Fetch
