import http from 'node:http';
import fs from 'node:fs';

const method = process.argv[2];
let params;
try { params = JSON.parse(process.argv[3] ?? (fs.readFileSync(0, 'utf8') || '{}')); }
catch { console.log(JSON.stringify({ ok: false, error: 'invalid_request' })); process.exit(1); }
const body = JSON.stringify({ method, params });
const request = http.request({ socketPath: process.env.NETFLEET_SOCKET, path: '/rpc', method: 'POST',
  headers: { Authorization: `Bearer ${process.env.NETFLEET_RPC_TOKEN}`, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
  timeout: 120000 }, response => {
  let output = '', size = 0;
  response.on('data', chunk => { size += chunk.length; if (size > 8 * 1024 * 1024) request.destroy(); else output += chunk; });
  response.on('end', () => { process.stdout.write(output); if (response.statusCode !== 200) process.exitCode = 1; });
});
request.on('timeout', () => request.destroy(new Error('timeout')));
request.on('error', () => { console.log(JSON.stringify({ ok: false, error: 'desktop_owner_unavailable' })); process.exitCode = 1; });
request.end(body);
