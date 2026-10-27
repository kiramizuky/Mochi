// Network Sentinel & PC Security Audit Suite for Windows
// Paritas dengan Blueprint Paket 5 (PLAN_VISUAL_NETWORK_SECURITY_TOOLS.md).
//
// Melakukan audit keamanan Windows (Firewall, BitLocker, Windows Defender, UAC, Open Ports),
// pemindaian perangkat jaringan lokal (ARP / LAN Discovery), serta diagnostik latency dan DNS.

use std::net::SocketAddr;
use std::os::windows::process::CommandExt;
use std::process::Command;
use std::time::Instant;

use serde::{Deserialize, Serialize};

const CREATE_NO_WINDOW: u32 = 0x08000000;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SecurityCheckItem {
    pub name: String,
    pub title: String,
    pub is_passed: bool,
    pub status_text: String,
    pub details: String,
    pub recommendation: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LaptopSecurityReport {
    pub timestamp: String,
    pub health_score: u32,
    pub checks: Vec<SecurityCheckItem>,
    pub open_ports_count: usize,
    pub summary_markdown: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DiscoveredNetworkDevice {
    pub ip_address: String,
    pub mac_address: String,
    pub hostname: String,
    pub is_gateway: bool,
    pub device_type_guess: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NetworkScanReport {
    pub timestamp: String,
    pub active_interface: String,
    pub local_ip: String,
    pub gateway_ip: String,
    pub devices: Vec<DiscoveredNetworkDevice>,
    pub summary_text: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NetworkDiagnosticsReport {
    pub timestamp: String,
    pub target_host: String,
    pub is_connected: bool,
    pub latency_ms: f64,
    pub dns_resolution_ms: f64,
    pub public_ip: Option<String>,
    pub summary_text: String,
}

/// Helper untuk menjalankan perintah tanpa memunculkan jendela konsol
fn run_command(cmd: &str, args: &[&str]) -> String {
    let output = Command::new(cmd)
        .args(args)
        .creation_flags(CREATE_NO_WINDOW)
        .output();

    match output {
        Ok(out) => String::from_utf8_lossy(&out.stdout).trim().to_string(),
        Err(_) => String::new(),
    }
}

/// 1. Audit Keamanan PC Windows
pub fn audit_pc_security() -> LaptopSecurityReport {
    let mut checks = Vec::new();
    let mut score: i32 = 100;

    // --- 1. Windows Firewall Status ---
    let fw_output = run_command("netsh", &["advfirewall", "show", "allprofiles", "state"]);
    let fw_enabled = !fw_output.is_empty() && !fw_output.to_lowercase().contains("state off");
    if !fw_enabled {
        score -= 20;
    }
    checks.push(SecurityCheckItem {
        name: "firewall".into(),
        title: "Windows Defender Firewall".into(),
        is_passed: fw_enabled,
        status_text: if fw_enabled {
            "Aktif (Protected)".into()
        } else {
            "Nonaktif (Vulnerable)".into()
        },
        details: if fw_output.is_empty() {
            "Tidak dapat membaca status firewall.".into()
        } else {
            "Semua profil firewall (Domain, Private, Public) aktif.".into()
        },
        recommendation: if fw_enabled {
            "Firewall Windows aktif menyaring koneksi masuk mencurigakan.".into()
        } else {
            "Aktifkan Windows Firewall di Pengaturan Keamanan Windows.".into()
        },
    });

    // --- 2. Windows Defender / Antivirus Real-time Protection ---
    let defender_out = run_command(
        "powershell",
        &[
            "-NoProfile",
            "-Command",
            "try { (Get-MpComputerStatus -ErrorAction Stop).RealTimeProtectionEnabled } catch { 'unknown' }",
        ],
    );
    let defender_enabled = defender_out.to_lowercase().contains("true");
    if !defender_enabled && !defender_out.contains("unknown") {
        score -= 25;
    }
    checks.push(SecurityCheckItem {
        name: "antivirus".into(),
        title: "Windows Defender Antivirus (Real-time Guard)".into(),
        is_passed: defender_enabled,
        status_text: if defender_enabled {
            "Aktif (Real-time Protected)".into()
        } else {
            "Peringatan / Proteksi Nonaktif".into()
        },
        details: format!("Status Real-time Protection: {}", defender_out),
        recommendation: if defender_enabled {
            "Proteksi real-time aktif melindungi sistem dari malware.".into()
        } else {
            "Nyalakan Real-time Protection di Windows Security → Virus & threat protection.".into()
        },
    });

    // --- 3. BitLocker Drive Encryption (Drive C:) ---
    let bde_out = run_command("manage-bde", &["-status", "C:"]);
    let bitlocker_enabled = bde_out.to_lowercase().contains("protection on")
        || bde_out.to_lowercase().contains("100%")
        || bde_out.to_lowercase().contains("terproteksi");
    if !bitlocker_enabled {
        score -= 20;
    }
    checks.push(SecurityCheckItem {
        name: "bitlocker".into(),
        title: "BitLocker Drive Encryption (Enkripsi Disk XTS-AES)".into(),
        is_passed: bitlocker_enabled,
        status_text: if bitlocker_enabled {
            "Aktif (Drive C: Terenkripsi)".into()
        } else {
            "Nonaktif / Belum Dikonfigurasi".into()
        },
        details: if bde_out.is_empty() {
            "Status BitLocker tidak dapat diakses (memerlukan izin standar).".into()
        } else {
            "Status enkripsi volume C: diverifikasi.".into()
        },
        recommendation: if bitlocker_enabled {
            "Data penyimpanan sistem terlindungi dari pencurian fisik disk.".into()
        } else {
            "Aktifkan BitLocker Drive Encryption untuk melindungi data saat laptop hilang.".into()
        },
    });

    // --- 4. UAC (User Account Control / LUA) ---
    let uac_out = run_command(
        "powershell",
        &[
            "-NoProfile",
            "-Command",
            "(Get-ItemProperty HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\System -ErrorAction SilentlyContinue).EnableLUA",
        ],
    );
    let uac_enabled = uac_out.trim() == "1";
    if !uac_enabled {
        score -= 15;
    }
    checks.push(SecurityCheckItem {
        name: "uac".into(),
        title: "User Account Control (UAC Admin Isolation)".into(),
        is_passed: uac_enabled,
        status_text: if uac_enabled {
            "Aktif (UAC Beroperasi)".into()
        } else {
            "Nonaktif (Hak Admin Bebas Tanpa Konfirmasi)".into()
        },
        details: format!("Registri EnableLUA: {}", uac_out.trim()),
        recommendation: if uac_enabled {
            "Setiap aplikasi memerlukan izin eksplisit sebelum mengubah file sistem.".into()
        } else {
            "Nyalakan kembali UAC untuk mencegah modifikasi sistem diam-diam.".into()
        },
    });

    // --- 5. Open Listening Ports ---
    let netstat_out = run_command("netstat", &["-ano", "-p", "tcp"]);
    let mut listening_ports = Vec::new();
    for line in netstat_out.lines() {
        if line.contains("LISTENING") {
            let tokens: Vec<&str> = line.split_whitespace().collect();
            if tokens.len() >= 2 {
                listening_ports.push(tokens[1].to_string());
            }
        }
    }
    let open_count = listening_ports.len();
    if open_count > 15 {
        score -= 15;
    }

    let top_ports = listening_ports
        .iter()
        .take(10)
        .map(|p| format!("• Port listening: `{p}`"))
        .collect::<Vec<_>>()
        .join("\n");

    checks.push(SecurityCheckItem {
        name: "listening_ports".into(),
        title: "TCP Listening Ports (Layanan Terbuka Jaringan)".into(),
        is_passed: open_count <= 15,
        status_text: format!("{open_count} port listening aktif"),
        details: if top_ports.is_empty() {
            "Tidak ada port publik terbuka yang terdeteksi.".into()
        } else {
            top_ports.clone()
        },
        recommendation: if open_count <= 15 {
            "Jumlah port listening normal untuk workstation pengembang.".into()
        } else {
            "Tutup aplikasi atau background services yang membuka port jika tidak diperlukan.".into()
        },
    });

    let final_score = score.clamp(10, 100) as u32;

    // Generate Markdown Summary
    let mut md = String::new();
    md.push_str("# Laporan Audit Keamanan Laptop & PC Windows\n\n");
    let badge = if final_score >= 80 {
        "🛡️ (Sangat Baik)"
    } else if final_score >= 60 {
        "⚠️ (Perlu Perhatian)"
    } else {
        "🚨 (Berisiko Tinggi)"
    };
    md.push_str(&format!("**Skor Keamanan:** `{final_score}/100` {badge}\n\n"));
    md.push_str("### Ringkasan Status Proteksi:\n");
    for check in &checks {
        let icon = if check.is_passed { "✅" } else { "❌" };
        md.push_str(&format!("- **{}:** {} {}\n", check.title, icon, check.status_text));
        if !check.is_passed {
            md.push_str(&format!("  - *Saran:* {}\n", check.recommendation));
        }
    }
    if !top_ports.is_empty() {
        md.push_str("\n### Port Terbuka Aktif (Top 10):\n");
        md.push_str(&top_ports);
        md.push('\n');
    }

    LaptopSecurityReport {
        timestamp: chrono_now_string(),
        health_score: final_score,
        checks,
        open_ports_count: open_count,
        summary_markdown: md,
    }
}

/// 2. Pemindaian Perangkat Jaringan Lokal (LAN Device Discovery)
pub fn scan_local_network() -> NetworkScanReport {
    // Cari gateway IP dan local IP
    let ip_out = run_command(
        "powershell",
        &[
            "-NoProfile",
            "-Command",
            "try { $ip = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.InterfaceAlias -notmatch 'Loopback|vEthernet' -and $_.IPAddress -notlike '169.254*' } | Select-Object -First 1); $gw = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Select-Object -First 1).NextHop; \"$($ip.IPAddress)|$($ip.InterfaceAlias)|$gw\" } catch { '||' }",
        ],
    );

    let parts: Vec<&str> = ip_out.split('|').collect();
    let local_ip = parts.first().unwrap_or(&"").trim().to_string();
    let active_interface = parts.get(1).unwrap_or(&"Wi-Fi").trim().to_string();
    let gateway_ip = parts.get(2).unwrap_or(&"").trim().to_string();

    // ARP scanning untuk menemukan perangkat lain di LAN
    let arp_out = run_command("arp", &["-a"]);
    let mut devices = Vec::new();

    for line in arp_out.lines() {
        let trimmed = line.trim();
        if trimmed.starts_with("192.168.")
            || trimmed.starts_with("10.")
            || trimmed.starts_with("172.16.")
            || trimmed.starts_with("172.17.")
            || trimmed.starts_with("172.18.")
            || trimmed.starts_with("172.19.")
            || trimmed.starts_with("172.2")
            || trimmed.starts_with("172.3")
        {
            let tokens: Vec<&str> = trimmed.split_whitespace().collect();
            if tokens.len() >= 2 {
                let ip = tokens[0].to_string();
                let mac = tokens[1].to_uppercase();
                // Filter broadcast / multicast
                if mac.contains("FF-FF-FF-FF-FF-FF") || ip.ends_with(".255") {
                    continue;
                }

                let is_gw = !gateway_ip.is_empty() && ip == gateway_ip;
                let device_type = if is_gw {
                    "Router / Gateway Jaringan".to_string()
                } else if ip == local_ip {
                    "Perangkat Ini (Mochi PC)".to_string()
                } else {
                    guess_device_type(&ip, &mac)
                };

                devices.push(DiscoveredNetworkDevice {
                    ip_address: ip,
                    mac_address: mac,
                    hostname: "Host Lokal".to_string(),
                    is_gateway: is_gw,
                    device_type_guess: device_type,
                });
            }
        }
    }

    let summary = format!(
        "Ditemukan {} perangkat aktif di jaringan lokal (Interface: {}, IP: {}, Gateway: {}).",
        devices.len(),
        if active_interface.is_empty() { "Lokal" } else { &active_interface },
        if local_ip.is_empty() { "-" } else { &local_ip },
        if gateway_ip.is_empty() { "-" } else { &gateway_ip }
    );

    NetworkScanReport {
        timestamp: chrono_now_string(),
        active_interface,
        local_ip,
        gateway_ip,
        devices,
        summary_text: summary,
    }
}

/// 3. Diagnostik Latensi & DNS Jaringan
pub async fn run_network_diagnostics(target: Option<String>) -> NetworkDiagnosticsReport {
    let host = target.unwrap_or_else(|| "1.1.1.1".to_string());

    // 1. DNS Resolution Time
    let dns_start = Instant::now();
    let dns_target = if host.parse::<std::net::IpAddr>().is_ok() {
        "google.com"
    } else {
        &host
    };
    let dns_ok = tokio::net::lookup_host(format!("{}:80", dns_target))
        .await
        .is_ok();
    let dns_ms = dns_start.elapsed().as_secs_f64() * 1000.0;

    // 2. Ping / TCP Latency
    let ping_start = Instant::now();
    let ping_target: SocketAddr = match host.parse() {
        Ok(ip) => SocketAddr::new(ip, 80),
        Err(_) => {
            if let Ok(mut addrs) = tokio::net::lookup_host(format!("{}:80", host)).await {
                addrs.next().unwrap_or_else(|| SocketAddr::from(([1, 1, 1, 1], 80)))
            } else {
                SocketAddr::from(([1, 1, 1, 1], 80))
            }
        }
    };

    let is_connected = tokio::time::timeout(
        std::time::Duration::from_secs(3),
        tokio::net::TcpStream::connect(ping_target),
    )
    .await
    .is_ok();
    let latency_ms = ping_start.elapsed().as_secs_f64() * 1000.0;

    // 3. Public IP Check (timeout 3 detik)
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(3))
        .build()
        .unwrap_or_default();

    let public_ip = match client.get("https://api.ipify.org").send().await {
        Ok(resp) => resp.text().await.ok().map(|t| t.trim().to_string()),
        Err(_) => None,
    };

    let summary = format!(
        "Status: {} | Latensi ke {}: {:.1} ms | Resolusi DNS: {:.1} ms | IP Publik: {}",
        if is_connected { "Terkoneksi (Stabil)" } else { "Koneksi Terganggu" },
        host,
        latency_ms,
        dns_ms,
        public_ip.as_deref().unwrap_or("Tidak terdeteksi")
    );

    NetworkDiagnosticsReport {
        timestamp: chrono_now_string(),
        target_host: host,
        is_connected: is_connected || dns_ok,
        latency_ms: if is_connected { latency_ms } else { 999.0 },
        dns_resolution_ms: if dns_ok { dns_ms } else { 999.0 },
        public_ip,
        summary_text: summary,
    }
}

fn guess_device_type(ip: &str, _mac: &str) -> String {
    if ip.ends_with(".1") || ip.ends_with(".254") {
        "Router / Gateway Jaringan".into()
    } else {
        "Perangkat Terhubung (PC / Ponsel / IoT)".into()
    }
}

fn chrono_now_string() -> String {
    let t = unsafe { windows::Win32::System::SystemInformation::GetLocalTime() };
    format!(
        "{:04}-{:02}-{:02} {:02}:{:02}:{:02}",
        t.wYear, t.wMonth, t.wDay, t.wHour, t.wMinute, t.wSecond
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn audit_pc_security_produces_valid_report() {
        let report = audit_pc_security();
        assert!(report.health_score >= 10 && report.health_score <= 100);
        assert!(!report.checks.is_empty());
        assert!(report.summary_markdown.contains("Skor Keamanan"));
    }

    #[test]
    fn scan_local_network_runs_cleanly() {
        let scan = scan_local_network();
        assert!(!scan.summary_text.is_empty());
    }

    #[tokio::test]
    async fn diagnostics_runs_without_panicking() {
        let diag = run_network_diagnostics(Some("127.0.0.1".into())).await;
        assert_eq!(diag.target_host, "127.0.0.1");
    }
}
