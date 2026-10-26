// Editor and terminal launchers.
//
// Only the fixed catalogue below can ever be started: the settings value is
// normalised against it, so a hand-edited settings.json cannot turn this into a
// generic command runner. The folder handed over is validated as an existing
// directory, and every target is an .exe started with separate arguments - no
// `cmd /C` anywhere - so a folder name containing `&`, `^` or `%` stays a name.

use std::path::PathBuf;
use std::process::Command;

#[cfg(windows)]
use std::os::windows::process::CommandExt;

use serde::Serialize;

/// Keeps GUI helpers from flashing a console window. Terminals are the
/// exception: PowerShell and Command Prompt need their own visible console.
const CREATE_NO_WINDOW: u32 = 0x0800_0000;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Editor,
    Terminal,
}

/// First entry is always the auto-detect choice.
pub const EDITORS: &[(&str, &str)] = &[
    ("auto", "Auto-detect"),
    ("vscode", "Visual Studio Code"),
    ("cursor", "Cursor"),
    ("windsurf", "Windsurf"),
    ("antigravity", "Antigravity"),
];

pub const TERMINALS: &[(&str, &str)] = &[
    ("auto", "Auto-detect"),
    ("windows_terminal", "Windows Terminal"),
    ("powershell", "Windows PowerShell"),
    ("pwsh", "PowerShell 7"),
    ("git_bash", "Git Bash"),
    ("cmd", "Command Prompt"),
];

/// Mirrors the macOS auto-detect order.
const AUTO_EDITOR_ORDER: &[&str] = &["cursor", "vscode", "windsurf", "antigravity"];
const AUTO_TERMINAL_ORDER: &[&str] = &[
    "windows_terminal",
    "pwsh",
    "powershell",
    "git_bash",
    // Command Prompt ships with Windows, so this always resolves.
    "cmd",
];

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LauncherOption {
    pub id: &'static str,
    pub name: &'static str,
    /// False means "not found on this PC"; the choice is still saved, so it
    /// starts working as soon as the app is installed.
    pub installed: bool,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LauncherCatalog {
    pub editors: Vec<LauncherOption>,
    pub terminals: Vec<LauncherOption>,
}

/// One fully resolved launch, separated from `spawn` so the safety properties
/// can be tested without starting a process.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LaunchPlan {
    pub program: PathBuf,
    pub args: Vec<String>,
    pub working_dir: Option<PathBuf>,
    pub hidden: bool,
}

pub fn catalog() -> LauncherCatalog {
    LauncherCatalog {
        editors: EDITORS
            .iter()
            .map(|(id, name)| LauncherOption {
                id,
                name,
                installed: editor_available(id),
            })
            .collect(),
        terminals: TERMINALS
            .iter()
            .map(|(id, name)| LauncherOption {
                id,
                name,
                installed: terminal_available(id),
            })
            .collect(),
    }
}

pub fn normalize_editor(value: &str) -> String {
    normalize(EDITORS, value)
}

pub fn normalize_terminal(value: &str) -> String {
    normalize(TERMINALS, value)
}

fn normalize(table: &[(&'static str, &'static str)], value: &str) -> String {
    let trimmed = value.trim();
    if table.iter().any(|(id, _)| *id == trimmed) {
        trimmed.to_string()
    } else {
        "auto".to_string()
    }
}

fn editor_available(id: &str) -> bool {
    if id == "auto" {
        resolve_editor(id).is_some()
    } else {
        editor_program(id).is_some()
    }
}

fn terminal_available(id: &str) -> bool {
    if id == "auto" {
        resolve_terminal(id).is_some()
    } else {
        terminal_program(id).is_some()
    }
}

/// Resolves the preferred editor, falling back to auto-detect when the chosen
/// one is no longer installed. Returns the catalogue id that was picked so the
/// caller never has to guess.
fn resolve_editor(preferred: &str) -> Option<(&'static str, PathBuf)> {
    if let Some(id) = known_id(EDITORS, preferred) {
        if id != "auto" {
            if let Some(program) = editor_program(id) {
                return Some((id, program));
            }
        }
    }
    AUTO_EDITOR_ORDER
        .iter()
        .find_map(|id| editor_program(id).map(|program| (*id, program)))
}

fn resolve_terminal(preferred: &str) -> Option<(&'static str, PathBuf)> {
    if let Some(id) = known_id(TERMINALS, preferred) {
        if id != "auto" {
            if let Some(program) = terminal_program(id) {
                return Some((id, program));
            }
        }
    }
    AUTO_TERMINAL_ORDER
        .iter()
        .find_map(|id| terminal_program(id).map(|program| (*id, program)))
}

fn known_id(table: &[(&'static str, &'static str)], value: &str) -> Option<&'static str> {
    table.iter().find(|(id, _)| *id == value).map(|(id, _)| *id)
}

/// Builds the command without starting it. `None` means no installed target
/// matched; the caller decides whether to fall back to Explorer.
pub fn plan(kind: Kind, preferred: &str, path: Option<&str>) -> Option<LaunchPlan> {
    let dir = valid_dir(path);
    match kind {
        Kind::Editor => {
            let (_, program) = resolve_editor(preferred)?;
            Some(LaunchPlan {
                program,
                args: dir
                    .map(|dir| vec![dir.to_string_lossy().into_owned()])
                    .unwrap_or_default(),
                working_dir: None,
                hidden: true,
            })
        }
        Kind::Terminal => {
            let (id, program) = resolve_terminal(preferred)?;
            let (args, working_dir, hidden) = match id {
                "windows_terminal" => (
                    dir.as_ref()
                        .map(|dir| vec!["-d".to_string(), dir.to_string_lossy().into_owned()])
                        .unwrap_or_default(),
                    None,
                    true,
                ),
                "git_bash" => (
                    dir.as_ref()
                        .map(|dir| vec![format!("--cd={}", dir.to_string_lossy())])
                        .unwrap_or_default(),
                    None,
                    true,
                ),
                // PowerShell, PowerShell 7 and Command Prompt open in the
                // folder through their working directory, not through a
                // command string that would need quoting.
                _ => (Vec::new(), dir, false),
            };
            Some(LaunchPlan {
                program,
                args,
                working_dir,
                hidden,
            })
        }
    }
}

pub fn open_editor(preferred: &str, path: Option<&str>) -> bool {
    if let Some(plan) = plan(Kind::Editor, preferred, path) {
        if spawn(&plan) {
            return true;
        }
    }
    // No editor, or it disappeared between detection and launch: show the
    // folder in Explorer so the button is never a dead end.
    if let Some(dir) = valid_dir(path) {
        let _ = Command::new("explorer").arg(dir).spawn();
    }
    false
}

pub fn open_terminal(preferred: &str, path: Option<&str>) -> bool {
    plan(Kind::Terminal, preferred, path)
        .map(|plan| spawn(&plan))
        .unwrap_or(false)
}

fn spawn(plan: &LaunchPlan) -> bool {
    let mut command = Command::new(&plan.program);
    command.args(&plan.args);
    if let Some(dir) = &plan.working_dir {
        command.current_dir(dir);
    }
    if plan.hidden {
        command.creation_flags(CREATE_NO_WINDOW);
    }
    command.spawn().is_ok()
}

/// Only an existing, absolute directory is ever handed to a launcher. A file,
/// a relative path, an empty string or a stale session path simply means "open
/// the app without a folder"; a relative path could otherwise be read as a
/// command-line switch by an editor.
fn valid_dir(path: Option<&str>) -> Option<PathBuf> {
    let raw = path?.trim();
    if raw.is_empty() {
        return None;
    }
    let candidate = PathBuf::from(raw);
    (candidate.is_absolute() && candidate.is_dir()).then_some(candidate)
}

fn editor_program(id: &str) -> Option<PathBuf> {
    match id {
        "vscode" => first_existing(&[
            env_path("LOCALAPPDATA", r"Programs\Microsoft VS Code\Code.exe"),
            env_path("ProgramFiles", r"Microsoft VS Code\Code.exe"),
            env_path("ProgramFiles(x86)", r"Microsoft VS Code\Code.exe"),
            env_path("LOCALAPPDATA", r"Programs\VSCodium\VSCodium.exe"),
        ])
        .or_else(|| find_exe_on_path("Code")),
        "cursor" => first_existing(&[
            env_path("LOCALAPPDATA", r"Programs\cursor\Cursor.exe"),
            env_path("ProgramFiles", r"Cursor\Cursor.exe"),
        ])
        .or_else(|| find_exe_on_path("Cursor")),
        "windsurf" => first_existing(&[
            env_path("LOCALAPPDATA", r"Programs\Windsurf\Windsurf.exe"),
            env_path("ProgramFiles", r"Windsurf\Windsurf.exe"),
        ])
        .or_else(|| find_exe_on_path("Windsurf")),
        "antigravity" => first_existing(&[
            env_path(
                "LOCALAPPDATA",
                r"Programs\Antigravity IDE\Antigravity IDE.exe",
            ),
            env_path("LOCALAPPDATA", r"Programs\Antigravity\Antigravity.exe"),
            env_path("LOCALAPPDATA", r"Programs\antigravity\Antigravity.exe"),
            env_path("ProgramFiles", r"Antigravity IDE\Antigravity IDE.exe"),
            env_path("ProgramFiles", r"Antigravity\Antigravity.exe"),
        ])
        .or_else(|| find_exe_on_path("Antigravity")),
        _ => None,
    }
}

fn terminal_program(id: &str) -> Option<PathBuf> {
    match id {
        "windows_terminal" => find_exe_on_path("wt").or_else(|| {
            env_path("LOCALAPPDATA", r"Microsoft\WindowsApps\wt.exe").filter(|path| path.is_file())
        }),
        "powershell" => env_path(
            "SystemRoot",
            r"System32\WindowsPowerShell\v1.0\powershell.exe",
        )
        .filter(|path| path.is_file())
        .or_else(|| find_exe_on_path("powershell")),
        "pwsh" => find_exe_on_path("pwsh").or_else(|| {
            env_path("ProgramFiles", r"PowerShell\7\pwsh.exe").filter(|path| path.is_file())
        }),
        "git_bash" => first_existing(&[
            env_path("ProgramFiles", r"Git\git-bash.exe"),
            env_path("LOCALAPPDATA", r"Programs\Git\git-bash.exe"),
            env_path("ProgramFiles(x86)", r"Git\git-bash.exe"),
        ])
        .or_else(|| find_exe_on_path("git-bash")),
        "cmd" => env_path("SystemRoot", r"System32\cmd.exe")
            .filter(|path| path.is_file())
            .or_else(|| find_exe_on_path("cmd")),
        _ => None,
    }
}

fn env_path(variable: &str, tail: &str) -> Option<PathBuf> {
    std::env::var_os(variable).map(|root| PathBuf::from(root).join(tail))
}

fn first_existing(candidates: &[Option<PathBuf>]) -> Option<PathBuf> {
    candidates
        .iter()
        .flatten()
        .find(|path| path.is_file())
        .cloned()
}

/// Only `.exe` is accepted. Looking up a bare stem would also match `code.cmd`,
/// which can only be run through `cmd /C` - exactly what this module avoids.
fn find_exe_on_path(stem: &str) -> Option<PathBuf> {
    let dirs = std::env::var_os("PATH")?;
    std::env::split_paths(&dirs)
        .map(|dir| dir.join(format!("{stem}.exe")))
        .find(|candidate| candidate.is_file())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_dir_string() -> String {
        std::env::temp_dir().to_string_lossy().into_owned()
    }

    #[test]
    fn catalogue_ids_are_unique_and_start_with_auto() {
        for table in [EDITORS, TERMINALS] {
            let unique: std::collections::HashSet<_> = table.iter().map(|(id, _)| id).collect();
            assert_eq!(unique.len(), table.len(), "duplicate launcher id");
            assert_eq!(table[0].0, "auto");
            assert!(table.iter().all(|(_, name)| !name.is_empty()));
        }
    }

    #[test]
    fn unknown_choices_normalize_to_auto() {
        for value in [
            "",
            "   ",
            "calc.exe",
            "C:\\Windows\\System32\\cmd.exe",
            "AUTO",
        ] {
            assert_eq!(normalize_editor(value), "auto", "{value}");
            assert_eq!(normalize_terminal(value), "auto", "{value}");
        }
        assert_eq!(normalize_editor("cursor"), "cursor");
        assert_eq!(normalize_terminal("powershell"), "powershell");
        assert_eq!(normalize_terminal(" pwsh "), "pwsh");
    }

    #[test]
    fn only_existing_directories_are_handed_over() {
        let dir = temp_dir_string();
        assert_eq!(
            valid_dir(Some(&dir)),
            Some(PathBuf::from(&dir)),
            "the temp folder is a directory"
        );
        assert_eq!(valid_dir(None), None);
        assert_eq!(valid_dir(Some("")), None);
        assert_eq!(valid_dir(Some("   ")), None);
        // A relative path could be read as a switch by the editor, so it is
        // refused even when it happens to exist relative to the app.
        assert_eq!(valid_dir(Some("src")), None, "a relative folder is refused");
        assert_eq!(
            valid_dir(Some(r"C:\definitely-not-a-real-folder-coucou")),
            None
        );

        let file = std::env::current_exe().expect("test executable path");
        let file = file.to_string_lossy().into_owned();
        assert_eq!(valid_dir(Some(&file)), None, "a file is not a folder");
    }

    #[test]
    fn terminal_plans_never_build_a_shell_command() {
        let dir = temp_dir_string();

        let cmd_plan = plan(Kind::Terminal, "cmd", Some(&dir)).expect("cmd.exe ships with Windows");
        assert!(cmd_plan.args.is_empty(), "no command string is built");
        assert_eq!(cmd_plan.working_dir, Some(PathBuf::from(&dir)));
        assert!(!cmd_plan.hidden, "the console window must be visible");

        if let Some(git_plan) = plan(Kind::Terminal, "git_bash", Some(&dir)) {
            assert_eq!(git_plan.args, vec![format!("--cd={dir}")]);
            assert_eq!(git_plan.working_dir, None);
        }

        if let Some(wt_plan) = plan(Kind::Terminal, "windows_terminal", Some(&dir)) {
            assert_eq!(wt_plan.args, vec!["-d".to_string(), dir.clone()]);
            assert_eq!(wt_plan.working_dir, None);
            assert!(wt_plan.hidden);
        }
    }

    #[test]
    fn editor_plans_pass_the_folder_as_one_argument() {
        if let Some(plan) = plan(Kind::Editor, "auto", Some("C:\\work & play\\%TEMP%")) {
            // The path is not a real directory, so it is not passed at all.
            assert!(plan.args.is_empty());
        }

        let dir = temp_dir_string();
        if let Some(plan) = plan(Kind::Editor, "auto", Some(&dir)) {
            assert_eq!(plan.args, vec![dir]);
            assert!(plan.hidden);
        }
    }

    #[test]
    fn unknown_launchers_are_never_programs() {
        assert_eq!(editor_program("calc.exe"), None);
        assert_eq!(terminal_program("calc.exe"), None);
        assert_eq!(editor_program("auto"), None);
        assert_eq!(terminal_program("auto"), None);
    }

    #[test]
    fn auto_detection_only_returns_an_installed_program() {
        if let Some((id, program)) = resolve_editor("auto") {
            assert!(AUTO_EDITOR_ORDER.contains(&id));
            assert!(program.is_file(), "{id} resolved to a missing file");
        }
        let (id, program) = resolve_terminal("auto").expect("cmd.exe always exists");
        assert!(AUTO_TERMINAL_ORDER.contains(&id));
        assert!(program.is_file());
    }

    #[test]
    fn a_missing_specific_choice_falls_back_to_auto() {
        // `not-installed` is not in the catalogue, so it behaves like auto.
        let dir = temp_dir_string();
        assert_eq!(
            plan(Kind::Terminal, "not-installed", Some(&dir)),
            plan(Kind::Terminal, "auto", Some(&dir))
        );
    }

    #[test]
    fn every_catalogue_entry_has_a_name_for_the_settings_window() {
        let catalog = catalog();
        assert_eq!(catalog.editors.len(), EDITORS.len());
        assert_eq!(catalog.terminals.len(), TERMINALS.len());
        assert!(catalog.editors[0].installed == resolve_editor("auto").is_some());
        assert!(catalog.terminals.iter().any(|option| option.id == "cmd"));
    }
}
