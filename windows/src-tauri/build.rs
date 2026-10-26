// Tauri build glue.
//
// `tauri.conf.json` bundles `../target/release/coucou-hook.exe`, and tauri-build
// refuses to compile when that file is missing. The release path always has it:
// `npm run pack` runs `npm run build` (which builds the hook) before invoking the
// Tauri CLI, and `npm run tauri dev` does the same through `predev`.
//
// `cargo test --workspace` has no such pre-step, and it should still work from a
// clean checkout. A debug build does not need the relay bundled — the app falls
// back to the release binary next to the test binary and, in `tauri dev`, to the
// copy the predev script built. So: strip only the resource entry for this
// build-script invocation when the hook is absent, and fail loudly in release
// rather than shipping an installer without the relay.

use serde_json::{json, Value};

fn hook_binary() -> std::path::PathBuf {
    // build.rs runs with `src-tauri/` as the working directory.
    std::path::Path::new("../target/release/coucou-hook.exe").into()
}

/// Removes `bundle.resources` from whatever config tauri-build is about to read,
/// preserving any other overlay the Tauri CLI may have passed in `TAURI_CONFIG`.
fn without_bundle_resources() {
    let mut config: Value = std::env::var("TAURI_CONFIG")
        .ok()
        .and_then(|raw| serde_json::from_str(&raw).ok())
        .filter(Value::is_object)
        .unwrap_or_else(|| json!({}));

    let root = config.as_object_mut().expect("checked above");
    let bundle = root.entry("bundle").or_insert_with(|| json!({}));
    if !bundle.is_object() {
        *bundle = json!({});
    }
    bundle
        .as_object_mut()
        .expect("just made an object")
        .insert("resources".into(), json!([]));

    std::env::set_var("TAURI_CONFIG", config.to_string());
}

/// Emits `rerun-if-changed` for a directory tree (Cargo only watches a directory
/// itself, not the files below it).
fn watch_dist(dir: &std::path::Path) {
    println!("cargo:rerun-if-changed={}", dir.display());
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            watch_dist(&path);
        } else {
            println!("cargo:rerun-if-changed={}", path.display());
        }
    }
}

fn main() {
    let hook = hook_binary();
    println!("cargo:rerun-if-changed={}", hook.display());
    // `generate_context!` embeds `../dist` at compile time, but Cargo has no
    // idea those files are inputs. Watch every asset so `npm run build` followed
    // by `cargo build` (the smoke-test path) cannot keep a stale front end.
    watch_dist(std::path::Path::new("../dist"));

    if !hook.exists() {
        let release = std::env::var("PROFILE").as_deref() == Ok("release");
        if release {
            panic!(
                "{} is missing. Build the relay first: \
                 `cargo build --release -p coucou-hook` (or use `npm run pack`, which does it for you).",
                hook.display()
            );
        }
        println!(
            "cargo:warning={} not built yet; this debug build will not bundle the relay. \
             Run `cargo build --release -p coucou-hook` (or the npm predev/prebuild script) before packaging.",
            hook.display()
        );
        without_bundle_resources();
    }

    tauri_build::build()
}
