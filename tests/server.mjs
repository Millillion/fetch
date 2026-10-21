// Local HTTP server for the Fetch tests (Node.js, no dependencies).
//   node tests/server.mjs            prints the base URL, serves until killed
import { createServer } from 'node:http';
import { gzipSync } from 'node:zlib';

const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
export function startServer(port = 0) {
  const server = createServer(async (req, res) => {
    const chunks = [];
    for await (const chunk of req) chunks.push(chunk);
    const body = Buffer.concat(chunks);
    const url = new URL(req.url, 'http://localhost');
    switch (url.pathname) {
    case '/text': res.writeHead(200, { 'content-type': 'text/plain; charset=utf-8', 'x-served-by': 'fetch-tests' }); res.end(req.method === 'HEAD' ? undefined : 'hello, fetch'); return;
    case '/json': res.writeHead(200, { 'content-type': 'application/json' }); res.end(JSON.stringify({ lean: 4, tags: ['a', 'b'] })); return;
    case '/echo': res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ method: req.method, body: body.toString('utf8'), test: req.headers['x-test'] ?? null,
        type: req.headers['content-type'] ?? null })); return;
    case '/redirect': res.writeHead(302, { location: '/text' }); res.end(); return;
    case '/redirect-chain': res.writeHead(301, { location: `http://${req.headers.host}/redirect` }); res.end(); return;
    case '/missing': res.writeHead(404, { 'content-type': 'text/plain' }); res.end('missing'); return;
    case '/stream': res.writeHead(200, { 'content-type': 'text/plain' });
      for (const part of ['chunk-1\n', 'chunk-2\n', 'chunk-3\n']) { res.write(part); await sleep(50); }
      res.end(); return;
    case '/slow': await sleep(3000); res.writeHead(200); res.end('late'); return;
    case '/bytes': res.writeHead(200, { 'content-type': 'application/octet-stream' }); res.end(Buffer.from([...Array(256).keys()])); return;
    case '/large': res.writeHead(200, { 'content-type': 'text/plain' }); res.end(Buffer.alloc(1 << 20, 'x')); return;
    case '/gzip': res.writeHead(200, { 'content-type': 'text/plain', 'content-encoding': 'gzip' }); res.end(gzipSync('compressed hello')); return;
    default: res.writeHead(404); res.end();
    }
  });
  return new Promise(resolve => server.listen(port, '127.0.0.1', () => resolve(server)));
}

if (import.meta.url === `file://${process.argv[1]}` || process.argv[1]?.endsWith('server.mjs')) {
  const server = await startServer();
  console.log(`http://127.0.0.1:${server.address().port}`);
}
