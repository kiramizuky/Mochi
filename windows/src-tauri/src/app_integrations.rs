// Desktop Application & Server Integrations for Windows.
// Connects Mochi to local apps: running GUI processes, App Launchers,
// Git repositories, and Docker Desktop / Containers.

use std::path::PathBuf;
use std::process::Command;

#[cfg(windows)]
use std::os::windows::process::CommandExt;

use serde::{Deserialize, Serialize};

const CREATE_NO_WINDOW: u32 = 0x0800_0000;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RunningAppInfo {
    pub pid: u32,
    pub process_name: String,
    pub window_title: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GitRepoStatus {
    pub is_repo: bool,
    pub branch: String,
    pub clean: bool,
    pub changed_files: Vec<String>,
    pub recent_commits: Vec<String>,
    pub summary_markdown: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DockerContainerInfo {
    pub id: String,
    pub name: String,
    pub image: String,
    pub status: String,
    pub ports: String,
    pub is_running: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DockerIntegrationStatus {
    pub is_available: bool,
    pub version: String,
    pub containers: Vec<DockerContainerInfo>,
    pub summary_markdown: String,
}

// ── 1. Running GUI Desktop Applications ──────────────────────────────────────

/// Enumerates running GUI applications with active window titles.
pub fn list_running_apps() -> Vec<RunningAppInfo> {
    let script = r#"
        Get-Process | Where-Object { $_.MainWindowTitle -and $_.MainWindowTitle.Trim().Length -gt 0 } |
        Select-Object Id, ProcessName, MainWindowTitle |
        ConvertTo-Json -Compress
    "#;

    let mut cmd = Command::new("powershell");
    cmd.args(["-NoProfile", "-NonInteractive", "-Command", script]);
    #[cfg(windows)]
    cmd.creation_flags(CREATE_NO_WINDOW);

    let output = match cmd.output() {
        Ok(out) if out.status.success() => String::from_utf8_lossy(&out.stdout).to_string(),
        _ => return Vec::new(),
    };

    let trimmed = output.trim();
    if trimmed.is_empty() {
        return Vec::new();
    }

    #[derive(Deserialize)]
    struct PsProcess {
        #[serde(rename = "Id")]
        id: u32,
        #[serde(rename = "ProcessName")]
        process_name: String,
        #[serde(rename = "MainWindowTitle")]
        main_window_title: String,
    }

    // PowerShell returns a single object if there's only 1 item, or an array if multiple
    if trimmed.starts_with('[') {
        if let Ok(list) = serde_json::from_str::<Vec<PsProcess>>(trimmed) {
            return list
                .into_iter()
                .map(|p| RunningAppInfo {
                    pid: p.id,
                    process_name: p.process_name,
                    window_title: p.main_window_title,
                })
                .collect();
        }
    } else if let Ok(single) = serde_json::from_str::<PsProcess>(trimmed) {
        return vec![RunningAppInfo {
            pid: single.id,
            process_name: single.process_name,
            window_title: single.main_window_title,
        }];
    }

    Vec::new()
}

// ── 2. Desktop Application Launcher & Controller ────────────────────────────

/// Launches a desktop app by name, using known system paths and launchers.
pub fn launch_app(name: &str, arg: Option<&str>) -> Result<String, String> {
    let target = name.trim().to_lowercase();
    match target.as_str() {
        "vscode" | "code" => {
            if crate::launchers::open_editor("vscode", arg) {
                Ok("Visual Studio Code berhasil dibuka.".into())
            } else {
                Err("Visual Studio Code tidak ditemukan di sistem.".into())
            }
        }
        "cursor" => {
            if crate::launchers::open_editor("cursor", arg) {
                Ok("Cursor IDE berhasil dibuka.".into())
            } else {
                Err("Cursor IDE tidak ditemukan di sistem.".into())
            }
        }
        "windsurf" => {
            if crate::launchers::open_editor("windsurf", arg) {
                Ok("Windsurf Editor berhasil dibuka.".into())
            } else {
                Err("Windsurf Editor tidak ditemukan di sistem.".into())
            }
        }
        "antigravity" => {
            if crate::launchers::open_editor("antigravity", arg) {
                Ok("Antigravity IDE berhasil dibuka.".into())
            } else {
                Err("Antigravity IDE tidak ditemukan di sistem.".into())
            }
        }
        "terminal" | "wt" => {
            if crate::launchers::open_terminal("windows_terminal", arg) {
                Ok("Windows Terminal berhasil dibuka.".into())
            } else {
                Err("Windows Terminal tidak ditemukan di sistem.".into())
            }
        }
        "powershell" => {
            if crate::launchers::open_terminal("powershell", arg) {
                Ok("Windows PowerShell berhasil dibuka.".into())
            } else {
                Err("Windows PowerShell tidak dapat dibuka.".into())
            }
        }
        "pwsh" => {
            if crate::launchers::open_terminal("pwsh", arg) {
                Ok("PowerShell 7 berhasil dibuka.".into())
            } else {
                Err("PowerShell 7 tidak ditemukan di sistem.".into())
            }
        }
        "git_bash" | "gitbash" => {
            if crate::launchers::open_terminal("git_bash", arg) {
                Ok("Git Bash berhasil dibuka.".into())
            } else {
                Err("Git Bash tidak ditemukan di sistem.".into())
            }
        }
        "cmd" | "command_prompt" => {
            if crate::launchers::open_terminal("cmd", arg) {
                Ok("Command Prompt berhasil dibuka.".into())
            } else {
                Err("Command Prompt tidak dapat dibuka.".into())
            }
        }
        "notepad" => spawn_system_cmd("notepad.exe", arg, "Notepad"),
        "calc" | "calculator" | "kalkulator" => spawn_system_cmd("calc.exe", None, "Kalkulator"),
        "explorer" | "file explorer" | "berkas" => {
            let mut cmd = Command::new("explorer.exe");
            if let Some(path) = arg {
                cmd.arg(path);
            }
            match cmd.spawn() {
                Ok(_) => Ok("File Explorer berhasil dibuka.".into()),
                Err(e) => Err(format!("Gagal membuka File Explorer: {e}")),
            }
        }
        "chrome" => spawn_system_cmd("chrome.exe", arg, "Google Chrome"),
        "edge" | "msedge" => spawn_system_cmd("msedge.exe", arg, "Microsoft Edge"),
        "word" | "winword" => spawn_system_cmd("winword.exe", arg, "Microsoft Word"),
        "excel" => spawn_system_cmd("excel.exe", arg, "Microsoft Excel"),
        "powerpoint" | "powerpnt" => spawn_system_cmd("powerpnt.exe", arg, "Microsoft PowerPoint"),
        "spotify" => spawn_system_cmd("spotify.exe", arg, "Spotify"),
        "taskmgr" | "task manager" => spawn_system_cmd("taskmgr.exe", None, "Task Manager"),
        custom => {
            // Safe launcher for standard apps
            let mut cmd = Command::new(custom);
            if let Some(a) = arg {
                cmd.arg(a);
            }
            match cmd.spawn() {
                Ok(_) => Ok(format!("Aplikasi '{custom}' berhasil dijalankan.")),
                Err(e) => Err(format!("Gagal menjalankan aplikasi '{custom}': {e}")),
            }
        }
    }
}

fn spawn_system_cmd(exe: &str, arg: Option<&str>, display_name: &str) -> Result<String, String> {
    let mut cmd = Command::new(exe);
    if let Some(a) = arg {
        cmd.arg(a);
    }
    match cmd.spawn() {
        Ok(_) => Ok(format!("{display_name} berhasil dibuka.")),
        Err(e) => Err(format!("Gagal membuka {display_name}: {e}")),
    }
}

/// Closes a process gracefully by name.
pub fn close_app(process_name: &str) -> Result<String, String> {
    let mut clean_name = process_name.trim().to_string();
    if !clean_name.to_lowercase().ends_with(".exe") {
        clean_name.push_str(".exe");
    }

    let mut cmd = Command::new("taskkill");
    cmd.args(["/IM", &clean_name]);
    #[cfg(windows)]
    cmd.creation_flags(CREATE_NO_WINDOW);

    match cmd.output() {
        Ok(out) if out.status.success() => {
            Ok(format!("Aplikasi '{clean_name}' berhasil ditutup."))
        }
        Ok(out) => {
            let err = String::from_utf8_lossy(&out.stderr);
            Err(format!("Gagal menutup '{clean_name}': {}", err.trim()))
        }
        Err(e) => Err(format!("Gagal mengeksekusi taskkill: {e}")),
    }
}

// ── 3. Git Repository Status ────────────────────────────────────────────────

/// Inspects local Git repository status for a given directory or workspace.
pub fn inspect_git_status(path: Option<&str>) -> GitRepoStatus {
    let target_dir = path
        .map(PathBuf::from)
        .or_else(|| std::env::current_dir().ok())
        .unwrap_or_else(|| PathBuf::from("."));

    // Check if inside work tree
    let mut check_cmd = Command::new("git");
    check_cmd.args(["rev-parse", "--is-inside-work-tree"]);
    check_cmd.current_dir(&target_dir);
    #[cfg(windows)]
    check_cmd.creation_flags(CREATE_NO_WINDOW);

    let is_repo = check_cmd
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false);

    if !is_repo {
        return GitRepoStatus {
            is_repo: false,
            branch: "-".into(),
            clean: true,
            changed_files: Vec::new(),
            recent_commits: Vec::new(),
            summary_markdown: format!(
                "Direktori `{}` bukan merupakan repositori Git aktif.",
                target_dir.display()
            ),
        };
    }

    // Branch
    let mut branch_cmd = Command::new("git");
    branch_cmd.args(["branch", "--show-current"]);
    branch_cmd.current_dir(&target_dir);
    #[cfg(windows)]
    branch_cmd.creation_flags(CREATE_NO_WINDOW);
    let branch = branch_cmd
        .output()
        .ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .filter(|b| !b.is_empty())
        .unwrap_or_else(|| "detached".into());

    // Status --short
    let mut status_cmd = Command::new("git");
    status_cmd.args(["status", "--short"]);
    status_cmd.current_dir(&target_dir);
    #[cfg(windows)]
    status_cmd.creation_flags(CREATE_NO_WINDOW);
    let status_out = status_cmd
        .output()
        .ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).to_string())
        .unwrap_or_default();

    let changed_files: Vec<String> = status_out
        .lines()
        .map(|l| l.trim().to_string())
        .filter(|l| !l.is_empty())
        .collect();
    let clean = changed_files.is_empty();

    // Recent commits
    let mut log_cmd = Command::new("git");
    log_cmd.args(["log", "-n", "3", "--oneline"]);
    log_cmd.current_dir(&target_dir);
    #[cfg(windows)]
    log_cmd.creation_flags(CREATE_NO_WINDOW);
    let recent_commits: Vec<String> = log_cmd
        .output()
        .ok()
        .map(|o| {
            String::from_utf8_lossy(&o.stdout)
                .lines()
                .map(|l| l.trim().to_string())
                .filter(|l| !l.is_empty())
                .collect()
        })
        .unwrap_or_default();

    let mut md = format!(
        "### Status Git Repository\n- **Folder:** `{}`\n- **Branch Aktif:** `{}`\n- **Status:** {}\n",
        target_dir.display(),
        branch,
        if clean { "Bersih (Tidak ada perubahan)" } else { "Ada perubahan lokal" }
    );

    if !clean {
        md.push_str("\n**Berkas yang Berubah:**\n");
        for f in &changed_files {
            md.push_str(&format!("- `{f}`\n"));
        }
    }

    if !recent_commits.is_empty() {
        md.push_str("\n**Commit Terakhir:**\n");
        for c in &recent_commits {
            md.push_str(&format!("- {c}\n"));
        }
    }

    GitRepoStatus {
        is_repo: true,
        branch,
        clean,
        changed_files,
        recent_commits,
        summary_markdown: md,
    }
}

// ── 4. Docker Desktop & Container Management ────────────────────────────────

/// Inspects Docker daemon and running/stopped containers on Windows.
pub fn inspect_docker() -> DockerIntegrationStatus {
    let mut ver_cmd = Command::new("docker");
    ver_cmd.args(["version", "--format", "{{.Server.Version}}"]);
    #[cfg(windows)]
    ver_cmd.creation_flags(CREATE_NO_WINDOW);

    let ver_out = match ver_cmd.output() {
        Ok(o) if o.status.success() => String::from_utf8_lossy(&o.stdout).trim().to_string(),
        _ => {
            return DockerIntegrationStatus {
                is_available: false,
                version: "".into(),
                containers: Vec::new(),
                summary_markdown: "Docker CLI atau daemon tidak aktif/tidak ditemukan di komputer ini.".into(),
            };
        }
    };

    let mut ps_cmd = Command::new("docker");
    ps_cmd.args([
        "ps",
        "-a",
        "--format",
        "{{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}",
    ]);
    #[cfg(windows)]
    ps_cmd.creation_flags(CREATE_NO_WINDOW);

    let mut containers = Vec::new();
    if let Ok(out) = ps_cmd.output() {
        if out.status.success() {
            let text = String::from_utf8_lossy(&out.stdout);
            for line in text.lines() {
                let parts: Vec<&str> = line.split('\t').collect();
                if parts.len() >= 4 {
                    let id = parts[0].trim().to_string();
                    let name = parts[1].trim().to_string();
                    let image = parts[2].trim().to_string();
                    let status = parts[3].trim().to_string();
                    let ports = parts.get(4).map(|p| p.trim().to_string()).unwrap_or_default();
                    let is_running = status.to_lowercase().starts_with("up");

                    containers.push(DockerContainerInfo {
                        id,
                        name,
                        image,
                        status,
                        ports,
                        is_running,
                    });
                }
            }
        }
    }

    let running_count = containers.iter().filter(|c| c.is_running).count();
    let mut md = format!(
        "### Docker Desktop (v{ver_out})\n- **Total Kontainer:** {}\n- **Sedang Berjalan:** {}\n\n",
        containers.len(),
        running_count
    );

    if containers.is_empty() {
        md.push_str("Tidak ada kontainer Docker yang ditemukan.\n");
    } else {
        md.push_str("| Nama | Status | Image | Port |\n| :--- | :--- | :--- | :--- |\n");
        for c in &containers {
            let icon = if c.is_running { "🟢" } else { "⚪" };
            md.push_str(&format!(
                "| {} **{}** | `{}` | `{}` | `{}` |\n",
                icon, c.name, c.status, c.image, c.ports
            ));
        }
    }

    DockerIntegrationStatus {
        is_available: true,
        version: ver_out,
        containers,
        summary_markdown: md,
    }
}

/// Executes a safe Docker container management action.
pub fn manage_docker_container(action: &str, container_id: &str) -> Result<String, String> {
    let clean_id = container_id.trim();
    if clean_id.is_empty() {
        return Err("ID kontainer tidak boleh kosong.".into());
    }

    match action.to_lowercase().as_str() {
        "restart" => {
            let mut cmd = Command::new("docker");
            cmd.args(["restart", clean_id]);
            #[cfg(windows)]
            cmd.creation_flags(CREATE_NO_WINDOW);
            match cmd.output() {
                Ok(o) if o.status.success() => Ok(format!("Kontainer '{clean_id}' berhasil di-restart.")),
                Ok(o) => Err(format!("Gagal restart kontainer: {}", String::from_utf8_lossy(&o.stderr).trim())),
                Err(e) => Err(format!("Gagal mengeksekusi Docker: {e}")),
            }
        }
        "start" => {
            let mut cmd = Command::new("docker");
            cmd.args(["start", clean_id]);
            #[cfg(windows)]
            cmd.creation_flags(CREATE_NO_WINDOW);
            match cmd.output() {
                Ok(o) if o.status.success() => Ok(format!("Kontainer '{clean_id}' berhasil dinyalakan.")),
                Ok(o) => Err(format!("Gagal menyalakan kontainer: {}", String::from_utf8_lossy(&o.stderr).trim())),
                Err(e) => Err(format!("Gagal mengeksekusi Docker: {e}")),
            }
        }
        "stop" => {
            let mut cmd = Command::new("docker");
            cmd.args(["stop", clean_id]);
            #[cfg(windows)]
            cmd.creation_flags(CREATE_NO_WINDOW);
            match cmd.output() {
                Ok(o) if o.status.success() => Ok(format!("Kontainer '{clean_id}' berhasil dimatikan.")),
                Ok(o) => Err(format!("Gagal mematikan kontainer: {}", String::from_utf8_lossy(&o.stderr).trim())),
                Err(e) => Err(format!("Gagal mengeksekusi Docker: {e}")),
            }
        }
        "logs" => {
            let mut cmd = Command::new("docker");
            cmd.args(["logs", "--tail", "40", clean_id]);
            #[cfg(windows)]
            cmd.creation_flags(CREATE_NO_WINDOW);
            match cmd.output() {
                Ok(o) => {
                    let out = String::from_utf8_lossy(&o.stdout);
                    let err = String::from_utf8_lossy(&o.stderr);
                    let combined = if out.is_empty() { err } else { out };
                    Ok(format!("### Log Kontainer ({clean_id})\n```text\n{}\n```", combined.trim()))
                }
                Err(e) => Err(format!("Gagal mengambil log kontainer: {e}")),
            }
        }
        unknown => Err(format!("Aksi Docker '{unknown}' tidak dikenali. Pilihan: restart, start, stop, logs")),
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SystemMetricsReport {
    pub cpu_percent: u32,
    pub ram_used_gb: f64,
    pub ram_total_gb: f64,
    pub ram_percent: u32,
    pub disk_used_gb: f64,
    pub disk_total_gb: f64,
    pub disk_percent: u32,
    pub battery_status: String,
    pub uptime: String,
    pub summary_markdown: String,
}

fn progress_bar(percent: u32) -> String {
    let filled = ((percent.min(100) + 5) / 10) as usize;
    let empty = 10usize.saturating_sub(filled);
    format!("[{}{}] {}%", "■".repeat(filled), "□".repeat(empty), percent)
}

/// Gathers live system metrics: CPU, RAM, Disk C, Battery, and Uptime.
pub fn inspect_system_metrics() -> SystemMetricsReport {
    let script = r#"
        $cpu = [math]::Round(((Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average))
        $os = Get-CimInstance Win32_OperatingSystem
        $totalRam = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
        $freeRam = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
        $usedRam = [math]::Round($totalRam - $freeRam, 1)
        $ramPct = [math]::Round(($usedRam / $totalRam) * 100)
        $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
        $totalDisk = [math]::Round($disk.Size / 1GB, 1)
        $freeDisk = [math]::Round($disk.FreeSpace / 1GB, 1)
        $usedDisk = [math]::Round($totalDisk - $freeDisk, 1)
        $diskPct = [math]::Round(($usedDisk / $totalDisk) * 100)
        $batt = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue
        $battStatus = if ($batt) { "$($batt.EstimatedChargeRemaining)%" } else { "Desktop / AC Power" }
        $uptime = (Get-Date) - $os.LastBootUpTime

        [PSCustomObject]@{
            cpuPercent = [int]$cpu
            ramUsedGb = [double]$usedRam
            ramTotalGb = [double]$totalRam
            ramPercent = [int]$ramPct
            diskUsedGb = [double]$usedDisk
            diskTotalGb = [double]$totalDisk
            diskPercent = [int]$diskPct
            batteryStatus = $battStatus
            uptime = "$($uptime.Days)d $($uptime.Hours)h $($uptime.Minutes)m"
        } | ConvertTo-Json -Compress
    "#;

    let mut cmd = Command::new("powershell");
    cmd.args(["-NoProfile", "-NonInteractive", "-Command", script]);
    #[cfg(windows)]
    cmd.creation_flags(CREATE_NO_WINDOW);

    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct RawMetrics {
        cpu_percent: u32,
        ram_used_gb: f64,
        ram_total_gb: f64,
        ram_percent: u32,
        disk_used_gb: f64,
        disk_total_gb: f64,
        disk_percent: u32,
        battery_status: String,
        uptime: String,
    }

    let raw: RawMetrics = match cmd.output() {
        Ok(out) if out.status.success() => {
            let trimmed = String::from_utf8_lossy(&out.stdout).trim().to_string();
            serde_json::from_str(&trimmed).unwrap_or(RawMetrics {
                cpu_percent: 0,
                ram_used_gb: 0.0,
                ram_total_gb: 0.0,
                ram_percent: 0,
                disk_used_gb: 0.0,
                disk_total_gb: 0.0,
                disk_percent: 0,
                battery_status: "Unknown".into(),
                uptime: "-".into(),
            })
        }
        _ => RawMetrics {
            cpu_percent: 0,
            ram_used_gb: 0.0,
            ram_total_gb: 0.0,
            ram_percent: 0,
            disk_used_gb: 0.0,
            disk_total_gb: 0.0,
            disk_percent: 0,
            battery_status: "Unknown".into(),
            uptime: "-".into(),
        },
    };

    let cpu_bar = progress_bar(raw.cpu_percent);
    let ram_bar = progress_bar(raw.ram_percent);
    let disk_bar = progress_bar(raw.disk_percent);

    let md = format!(
        "### Status Kesehatan Sistem Windows\n        • **Beban CPU:** {cpu_bar}\n        • **Memori RAM:** `{:.1} / {:.1} GB` {ram_bar}\n        • **Penyimpanan (C:):** `{:.1} / {:.1} GB` {disk_bar}\n        • **Daya / Baterai:** {}\n        • **Uptime:** {}\n",
        raw.ram_used_gb, raw.ram_total_gb,
        raw.disk_used_gb, raw.disk_total_gb,
        raw.battery_status,
        raw.uptime
    );

    SystemMetricsReport {
        cpu_percent: raw.cpu_percent,
        ram_used_gb: raw.ram_used_gb,
        ram_total_gb: raw.ram_total_gb,
        ram_percent: raw.ram_percent,
        disk_used_gb: raw.disk_used_gb,
        disk_total_gb: raw.disk_total_gb,
        disk_percent: raw.disk_percent,
        battery_status: raw.battery_status,
        uptime: raw.uptime,
        summary_markdown: md,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn list_running_apps_runs_without_panicking() {
        let apps = list_running_apps();
        // Just verify it returns a list without panicking
        let _ = apps.len();
    }

    #[test]
    fn inspect_git_status_runs_cleanly() {
        let status = inspect_git_status(None);
        assert!(!status.summary_markdown.is_empty());
    }

    #[test]
    fn docker_inspection_does_not_panic_when_cli_missing_or_inactive() {
        let docker = inspect_docker();
        assert!(!docker.summary_markdown.is_empty());
    }
}
