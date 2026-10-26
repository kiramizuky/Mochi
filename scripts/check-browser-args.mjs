#!/usr/bin/env node
// WebView2 allows one browser environment per app, and its options are fixed by
// the first webview created. If the island (tauri.conf.json) and the settings
// window (BROWSER_ARGS in lib.rs) disagree, the second window silently comes up
// blank. This check also refuses the old `msSmartScreenProtection` opt-out.

import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const windows = resolve(dirname(fileURLToPath(import.meta.url)), "..", "windows");
const config = JSON.parse(readFileSync(join(windows, "src-tauri", "tauri.conf.json"), "utf8"));
const rust = readFileSync(join(windows, "src-tauri", "src", "lib.rs"), "utf8");

const island = config.app?.windows?.[0]?.additionalBrowserArgs;
if (typeof island !== "string" || !island.trim()) {
  console.error("tauri.conf.json: the island has no additionalBrowserArgs");
  process.exit(1);
}

const match = rust.match(/const BROWSER_ARGS:\s*&str\s*=\s*"([^"]*)";/);
if (!match) {
  console.error("src-tauri/src/lib.rs: BROWSER_ARGS not found");
  process.exit(1);
}
const settings = match[1];

if (island !== settings) {
  console.error("WebView2 arguments disagree between the island and Settings:");
  console.error(`  tauri.conf.json: ${island}`);
  console.error(`  lib.rs:          ${settings}`);
  process.exit(1);
}

// Match the actual switch, not the comment that explains why it is gone.
if (/--disable-features=[^\s"]*msSmartScreenProtection/.test(island)) {
  console.error("msSmartScreenProtection must never be disabled.");
  process.exit(1);
}

console.log("WebView2 arguments are identical and keep SmartScreen enabled.");
