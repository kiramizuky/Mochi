// Serves windows/release/ over loopback so a debug build can exercise the real
// update check against `latest.json`. Release builds ignore the endpoint
// override, so this can never redirect a shipped app.
//
//   npm run feed:serve
//   $env:COUCOU_UPDATER_ENDPOINT = "http://127.0.0.1:8787/latest.json"
//   npm run tauri dev
//
// Then open Settings: the Updates card should announce the version in the
// manifest. Do not click Install unless you mean to run that installer.

import { createServer } from "node:http";
import { readFileSync, existsSync, statSync } from "node:fs";
import { extname, join, normalize, resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");

function arg(name, fallback) {
  const i = process.argv.indexOf(`--${name}`);
  return i === -1 ? fallback : process.argv[i + 1];
}

const dir = resolve(root, arg("dir", "release"));
const port = Number(arg("port", "8787"));
const types = {
  ".json": "application/json; charset=utf-8",
  ".exe": "application/octet-stream",
  ".sig": "text/plain; charset=utf-8",
  ".txt": "text/plain; charset=utf-8",
};

createServer((req, res) => {
  const path = decodeURIComponent(new URL(req.url ?? "/", "http://127.0.0.1").pathname);
  const file = join(dir, normalize(path).replace(/^([/\\])+/, ""));
  if (!file.startsWith(dir) || !existsSync(file) || !statSync(file).isFile()) {
    res.writeHead(404, { "content-type": "text/plain" });
    res.end("not found\n");
    return;
  }
  const body = readFileSync(file);
  res.writeHead(200, {
    "content-type": types[extname(file)] ?? "application/octet-stream",
    "content-length": body.length,
    "cache-control": "no-store",
  });
  res.end(body);
}).listen(port, "127.0.0.1", () => {
  console.log(`\n  Local update feed: http://127.0.0.1:${port}/latest.json\n`);
  console.log(`  Serving ${dir}\n`);
});
