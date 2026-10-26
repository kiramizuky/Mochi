#!/usr/bin/env node
// Fails when the three places that carry the Windows version disagree.
// A mismatch makes the installer, the About window and the release tag tell
// different stories, and Tauri happily builds it anyway.

import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const windows = join(root, "windows");

const read = (path) => readFileSync(join(windows, path), "utf8");

const pkg = JSON.parse(read("package.json")).version;
const tauri = JSON.parse(read("src-tauri/tauri.conf.json")).version;

const cargo = read("Cargo.toml");
const workspace = cargo.match(/\[workspace\.package\][\s\S]*?\bversion\s*=\s*"([^"]+)"/);
if (!workspace) {
  console.error("windows/Cargo.toml has no [workspace.package] version");
  process.exit(1);
}
const rust = workspace[1];

const versions = { "package.json": pkg, "tauri.conf.json": tauri, "Cargo.toml": rust };
const unique = new Set(Object.values(versions));

if (unique.size !== 1) {
  console.error("Windows version mismatch:");
  for (const [file, version] of Object.entries(versions)) console.error(`  ${file}: ${version}`);
  process.exit(1);
}

if (!/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/.test(pkg)) {
  console.error(`Not a semantic version: ${pkg}`);
  process.exit(1);
}

console.log(`Windows version is consistent: ${pkg}`);
