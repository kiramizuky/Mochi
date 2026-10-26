// Builds release/latest.json, the static update manifest the app reads from
// https://github.com/<repo>/releases/latest/download/latest.json.
//
// Run after the *final* installer has been Authenticode-signed and re-signed
// with `tauri signer sign --app-version <version>`. Authenticode changes the
// installer bytes, which invalidates any updater signature made before it, so
// the `.sig` this script reads must be the one produced last.
//
//   node scripts/updater-feed.mjs
//   node scripts/updater-feed.mjs --url http://127.0.0.1:8787/Coucou-Windows-0.1.2-setup.exe
//
// The manifest and the signature are public; the private update key never
// belongs in this repository or in an artifact.

import { readFileSync, writeFileSync, existsSync, statSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");

function arg(name, fallback) {
  const i = process.argv.indexOf(`--${name}`);
  return i === -1 ? fallback : process.argv[i + 1];
}

const repo = arg("repo", process.env.GITHUB_REPOSITORY ?? "kiramizuky/Mochi");
const { version } = JSON.parse(readFileSync(join(root, "src-tauri", "tauri.conf.json"), "utf8"));
const tag = arg("tag", `v${version}`);
const installer = resolve(root, arg("installer", `release/Coucou-Windows-${version}-setup.exe`));
const signaturePath = resolve(root, arg("signature", `${installer}.sig`));
const out = resolve(root, arg("out", "release/latest.json"));
const notesFile = arg("notes-file", null);
const notes = notesFile
  ? readFileSync(resolve(root, notesFile), "utf8").trim()
  : arg("notes", `Coucou ${version}. See the release notes on GitHub for the full list of changes.`);

if (!/^\d+\.\d+\.\d+(?:[-+].*)?$/.test(version)) {
  throw new Error(`tauri.conf.json version "${version}" is not semver; the updater cannot parse it`);
}
if (!existsSync(installer)) {
  throw new Error(`installer not found: ${installer}`);
}
if (!existsSync(signaturePath)) {
  throw new Error(`updater signature not found: ${signaturePath} (run \`tauri signer sign\` first)`);
}
if (statSync(installer).size === 0) {
  throw new Error(`installer is empty: ${installer}`);
}

const signature = readFileSync(signaturePath, "utf8").trim();
// `tauri signer sign` writes the single-line base64 form the updater expects in
// the manifest. Decode a copy only to prove it is a real minisign signature and
// that it is bound to this version (`requireSignedVersion`).
let decodedSignature = "";
try {
  decodedSignature = Buffer.from(signature, "base64").toString("utf8");
} catch {
  decodedSignature = "";
}
if (!decodedSignature.includes("trusted comment:")) {
  throw new Error(`${signaturePath} is not a Tauri/minisign signature`);
}
if (!decodedSignature.includes(`version:${version}`)) {
  throw new Error(
    `${signaturePath} is not bound to version ${version}; sign with ` +
    `\`tauri signer sign --app-version ${version}\` after the final Authenticode signature`,
  );
}

const url = arg("url", `https://github.com/${repo}/releases/download/${tag}/${encodeURIComponent(installer.split(/[\\/]/).pop())}`);
if (!/^https?:\/\//.test(url)) {
  throw new Error(`download URL must be http(s): ${url}`);
}

const manifest = {
  version,
  notes,
  pub_date: new Date().toISOString(),
  platforms: {
    // NSIS on x64. `tauri bundle --no-binary-patching` keeps this single
    // bundle type, so the plain `windows-x86_64` key is enough.
    "windows-x86_64": {
      signature,
      url,
    },
  },
};

writeFileSync(out, `${JSON.stringify(manifest, null, 2)}\n`, "utf8");

console.log(`\n  Update manifest written — Coucou ${version}\n`);
console.log(`  ${out}`);
console.log(`  ${url}`);
console.log(`  Signature: ${signaturePath}\n`);
