# fetch

A fetch-style HTTP client for Lean 4, built on the `Std.Http` request, response, header and URI types.

**Status: in development. The API is not implemented yet.**

## Goals

- An API modeled on the web platform's `fetch`: `fetch url { method, headers, body, redirect, timeout }`,
  returning a `Std.Http.Response` with `ok`, `status`, `text`, `json`, `bytes` and a streaming body.
- Use `Std.Http` types throughout, so requests and responses interoperate with `Std.Http` servers
  and with a future core HTTP client.
- HTTPS everywhere.
- Works on native Lean and on Node.js through [Lasm](https://github.com/Millillion/lasm), with
  transport backends behind one small interface.

## Requirements

Lean `v4.35.0`.

## License

MIT
