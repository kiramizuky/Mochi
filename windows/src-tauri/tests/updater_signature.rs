// Release-only check: the installer published in latest.json must verify with
// the updater public key embedded in tauri.conf.json, and the signature must be
// bound to the manifest's version (requireSignedVersion).
//
// `cargo test --workspace` skips this when the artifacts are absent. The release
// workflow runs it explicitly after writing latest.json:
//
//   COUCOU_VERIFY_FEED=release/latest.json \
//   COUCOU_VERIFY_INSTALLER=release/Coucou-Windows-X.Y.Z-setup.exe \
//   cargo test --test updater_signature

use std::fs;
use std::path::PathBuf;

use base64::engine::general_purpose::STANDARD;
use base64::Engine;
use minisign_verify::{PublicKey, Signature};

fn manifest_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

/// Cargo may run the test with the package directory as cwd. Make relative
/// artifact paths work from `windows/` (the release workflow) and from
/// `windows/src-tauri/`.
fn resolve(path: &str) -> PathBuf {
    let path = PathBuf::from(path);
    if path.is_absolute() {
        path
    } else {
        manifest_dir()
            .parent()
            .expect("windows directory")
            .join(path)
    }
}

fn decode_text(value: &str) -> Result<String, String> {
    let bytes = STANDARD
        .decode(value.trim())
        .map_err(|err| format!("base64: {err}"))?;
    String::from_utf8(bytes).map_err(|err| format!("utf-8: {err}"))
}

#[test]
fn published_installer_verifies_against_the_embedded_update_key() {
    let (Ok(feed), Ok(installer)) = (
        std::env::var("COUCOU_VERIFY_FEED"),
        std::env::var("COUCOU_VERIFY_INSTALLER"),
    ) else {
        eprintln!("skipped: set COUCOU_VERIFY_FEED and COUCOU_VERIFY_INSTALLER to check a release");
        return;
    };

    let config: serde_json::Value = serde_json::from_str(
        &fs::read_to_string(manifest_dir().join("tauri.conf.json")).expect("tauri.conf.json"),
    )
    .expect("valid tauri.conf.json");
    let version = config["version"].as_str().expect("config version");
    let pubkey = config["plugins"]["updater"]["pubkey"]
        .as_str()
        .expect("plugins.updater.pubkey");

    // The configured public key is base64 of the whole minisign .pub file; its
    // second line is the key material.
    let decoded_pubkey = decode_text(pubkey).expect("decode pubkey");
    let key_line = decoded_pubkey
        .lines()
        .nth(1)
        .expect("minisign public key line");
    let public_key = PublicKey::from_base64(key_line).expect("parse public key");

    let feed: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(resolve(&feed)).expect("read update feed"))
            .expect("valid update feed");
    assert_eq!(feed["version"], version, "feed announces another version");

    let signature_b64 = feed["platforms"]["windows-x86_64"]["signature"]
        .as_str()
        .expect("windows-x86_64 signature");
    let decoded_signature = decode_text(signature_b64).expect("decode signature");
    assert!(
        decoded_signature.contains(&format!("version:{version}")),
        "signature is not bound to version {version}"
    );
    let signature = Signature::decode(&decoded_signature).expect("parse signature");

    let content = fs::read(resolve(&installer)).expect("read installer");
    public_key
        .verify(&content, &signature, false)
        .expect("installer does not match latest.json");
}
