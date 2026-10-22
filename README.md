# fetch

A fetch-style HTTP client for Lean 4, built on the `Std.Http` types. It runs on
native Lean and on Node.js through [Lasm](https://github.com/Millillion/lasm).

**Status: early (0.1.0, unreleased; no tags or releases yet).** The API below is
implemented and its test suite (17 cases per transport, plus HTTPS and the plain
`curl` subprocess pattern) passes natively and under Lasm (Node.js 26.12.1) on Linux
x86-64 and ARM64, macOS x86-64 and ARM64, and Windows x86-64, in Lasm's ecosystem CI
([compatibility list](https://github.com/Millillion/lasm/blob/main/docs/COMPATIBILITY.md)).
The API may still change.

```lean
import Fetch
open Fetch

def main : IO Unit := do
  let response ← (fetch "https://example.com/").block
  IO.println s!"{response.status} {response.ok}"
  IO.println (← response.text.block)
```

## API

`fetch (url : String) (options : Options := {}) : Async Fetch.Response` returns once the
status and headers have arrived. `Fetch.Response` is `Std.Http.Response Fetch.Body`; the
body streams from the network.

| Options field | Type | Default | Meaning |
| --- | --- | --- | --- |
| `method` | `Std.Http.Method` | `.get` | Request method. |
| `headers` | `Std.Http.Headers` | empty | Request headers; `Options.header name value` adds one. |
| `body` | `Option ByteArray` | `none` | Request body; `Options.text` and `Options.json` set it (JSON also sets `content-type`). |
| `redirect` | `Redirect` | `.follow` | `.follow` (up to 20), `.manual` (return the 3xx response) or `.error` (throw). |
| `timeout` | `Option Nat` | `none` | Milliseconds for the whole exchange, including the body. |
| `backend` | `Backend` | `.auto` | `.node`, `.libcurl`, `.curl`, or `.auto` (see below). |
| `transport` | `Option Transport` | `none` | A custom transport. |

| Response | Type | Meaning |
| --- | --- | --- |
| `status` | `UInt16` | Status code. `line.status` is the `Std.Http.Status`. |
| `ok` | `Bool` | Status in 200–299. HTTP error statuses are responses, not exceptions. |
| `statusText`, `url`, `redirected`, `transport` | | Reason phrase, final URL, whether redirects were followed, which transport ran. |
| `headers`, `header? name` | `Std.Http.Headers`, `Option String` | Response headers (names in lower case). |
| `text`, `bytes`, `json` | `Async String`, `Async ByteArray`, `Async Lean.Json` | Read the whole body. |
| `body.stream` | `Std.Http.Body.Stream` | Read the body chunk by chunk (`recv`). |
| `close` | `Async Unit` | Stop reading and release the connection. |

Network failures, timeouts and refused redirects throw `IO.Error`.

## Transports

| Backend | Where | How |
| --- | --- | --- |
| `node` | Lean compiled by Lasm, running in Node.js | Node's global `fetch` (undici), through Lasm's host call interface. HTTPS uses Node's TLS. |
| `libcurl` | native Lean | libcurl loaded at run time (`libcurl.so.4`, `libcurl.4.dylib`, `libcurl.dll`; override with `FETCH_LIBCURL`). No build-time dependency on libcurl. |
| `curl` | native Lean, and Lasm | The `curl` command-line tool through `IO.Process`. |

`.auto` uses `node` under Lasm; natively it uses `libcurl` when it loads, otherwise the
`curl` tool (Windows ships `curl.exe` but no libcurl DLL). Responses are decompressed
(gzip, deflate, brotli where supported) by every backend.

Building the package needs only Lean: the C transport shim (`c/fetch_shim.c`) is compiled
with Lean's own compiler.

## Tests

```sh
lake build FetchTest
node tests/server.mjs          # prints the local test server's URL
.lake/build/bin/FetchTest http://127.0.0.1:PORT [--online]
```

Under Lasm, build `FetchTest.lean` with `npx lasm build FetchTest.lean` in this package and run
`node dist/main.mjs http://127.0.0.1:PORT`. `scripts/test.mjs` does both against one server.

## License

MIT
