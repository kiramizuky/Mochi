// Copies the installer Tauri buries in target/release/bundle/nsis/ into
// windows/release/, with the name it ships under. Used by `npm run pack` and by
// the release workflow, so both produce exactly the same file names.

import { readFileSync, mkdirSync, copyFileSync, readdirSync, statSync, writeFileSync, existsSync, rmSync } from "node:fs";
import { createHash } from "node:crypto";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const bundleDir = join(root, "target", "release", "bundle", "nsis");
const outDir = join(root, "release");

const { version } = JSON.parse(readFileSync(join(root, "src-tauri", "tauri.conf.json"), "utf8"));

let installers = [];
try {
  installers = readdirSync(bundleDir).filter((f) => f.endsWith("-setup.exe"));
} catch {
  console.error(`No installer in ${bundleDir} — run \`npm run tauri build\` first.`);
  process.exit(1);
}
if (installers.length === 0) {
  console.error(`No installer in ${bundleDir} — run \`npm run tauri build\` first.`);
  process.exit(1);
}

// Newest wins, in case an older build is still lying around.
const built = installers
  .map((f) => join(bundleDir, f))
  .sort((a, b) => statSync(b).mtimeMs - statSync(a).mtimeMs)[0];

mkdirSync(outDir, { recursive: true });
const versioned = join(outDir, `Mochi-Windows-${version}-setup.exe`);
const rolling = join(outDir, "Mochi-Windows-setup.exe");
copyFileSync(built, versioned);
copyFileSync(built, rolling);

// The updater signature must be regenerated after Authenticode signing, so the
// release workflow calls this script after `tauri signer sign`. A local
// `npm run pack` has no update key and no signature, which is fine: it is not
// meant to be published as an update.
//
// A `.sig` left over from an earlier bundle is *not* fine. `tauri build` rewrites
// the installer but leaves the old signature next to it, and that signature
// covers different bytes. Copy only a signature that is at least as new as the
// installer and is bound to this version, and delete any stale release copy so
// nobody publishes it by accident.
const sigSource = `${built}.sig`;
const sigTarget = `${versioned}.sig`;
const rollingSig = `${rolling}.sig`;
let sigCopied = false;
let sigProblem = null;

if (existsSync(sigSource)) {
  const installerTime = statSync(built).mtimeMs;
  const sigTime = statSync(sigSource).mtimeMs;
  // Allow one second of filesystem timestamp granularity.
  if (sigTime + 1000 < installerTime) {
    sigProblem = `signature is older than the installer — run \`tauri signer sign\` again`;
  } else {
    let decoded = "";
    try {
      decoded = Buffer.from(readFileSync(sigSource, "utf8").trim(), "base64").toString("utf8");
    } catch {
      decoded = "";
    }
    if (!decoded.includes(`version:${version}`)) {
      sigProblem = `signature is not bound to version ${version}`;
    } else {
      copyFileSync(sigSource, sigTarget);
      copyFileSync(sigSource, rollingSig);
      sigCopied = true;
    }
  }
}

if (!sigCopied) {
  // Never leave a previous run's signature behind next to a rebuilt installer.
  for (const stale of [sigTarget, rollingSig]) {
    if (existsSync(stale)) {
      rmSync(stale, { force: true });
      sigProblem ??= `${stale} was stale and has been removed`;
    }
  }
}

// SHA-256 sidecar for UAT/Downloads so a tester can verify what they ran.
// Signed installers come from the release workflow; a local `npm run pack`
// still produces an unsigned installer for development.
const digest = createHash("sha256").update(readFileSync(versioned)).digest("hex");
const checksum = join(outDir, `Mochi-Windows-${version}-setup.exe.sha256`);
writeFileSync(checksum, `${digest}  Mochi-Windows-${version}-setup.exe\n`, "utf8");

const mb = (statSync(versioned).size / 1024 / 1024).toFixed(2);
console.log(`\n  Installer ready — ${mb} MB\n`);
console.log(`  ${versioned}`);
console.log(`  ${rolling}`);
console.log(`  SHA-256: ${digest}\n`);
console.log(`  Checksum written to ${checksum}\n`);
if (sigCopied) {
  console.log(`  Updater signature copied to ${sigTarget}\n`);
} else if (sigProblem) {
  console.log(`  Updater signature NOT copied: ${sigProblem}\n`);
} else {
  console.log("  No updater signature next to the bundled installer (unsigned local build).\n");
}
