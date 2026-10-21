// Run FetchTest against the local test server.
//   node scripts/test.mjs native [--online]   (after `lake build FetchTest`)
//   node scripts/test.mjs lasm [--online]     (after `npx lasm build FetchTest.lean`)
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { startServer } from '../tests/server.mjs';

const root = fileURLToPath(new URL('../', import.meta.url));
const [mode = 'native', ...flags] = process.argv.slice(2);
const server = await startServer();
const base = `http://127.0.0.1:${server.address().port}`;
const command = mode === 'lasm'
  ? [process.execPath, join(root, 'dist/main.mjs')]
  : [join(root, '.lake/build/bin', process.platform === 'win32' ? 'FetchTest.exe' : 'FetchTest')];
// The test server runs in this process: run the test asynchronously so it can answer.
const { spawn } = await import('node:child_process');
const child = spawn(command[0], [...command.slice(1), base, ...flags], { stdio: 'inherit' });
const code = await new Promise(resolve => child.on('close', resolve));
server.close();
process.exit(code ?? 1);
