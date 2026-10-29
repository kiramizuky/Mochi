// Windows Webcam & Visual Perception Module
// Paritas dengan Blueprint Paket 6 & 7 (docs/PLAN_VISUAL_NETWORK_SECURITY_TOOLS.md).
//
// Menyediakan kapabilitas akses kamera (Webcam), penangkapan foto resolusi tinggi,
// dan ekstraksi gambar instan untuk dianalisis oleh model multimodal AI (Vision VLM).
// Mengikuti standar privasi: sensor diinisialisasi sesaat dan langsung dilepas (0% CPU idle, zero background recording).

use std::os::windows::process::CommandExt;
use std::process::Command;

use serde::{Deserialize, Serialize};

const CREATE_NO_WINDOW: u32 = 0x0800_0000;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CameraDeviceInfo {
    pub name: String,
    pub device_id: String,
    pub status: String,
    pub is_webcam: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CameraSnapshot {
    pub file_path: String,
    pub size_bytes: usize,
    pub base64_image: String,
    pub timestamp: String,
    pub summary_markdown: String,
}

#[derive(Deserialize)]
struct RawDevice {
    #[serde(rename = "Name")]
    name: Option<String>,
    #[serde(rename = "DeviceID")]
    device_id: Option<String>,
    #[serde(rename = "Status")]
    status: Option<String>,
}

#[derive(Deserialize)]
struct RawCaptureResult {
    success: bool,
    #[serde(rename = "filePath")]
    file_path: String,
    #[serde(rename = "sizeBytes")]
    size_bytes: usize,
    #[serde(rename = "base64Image")]
    base64_image: String,
    error: Option<String>,
}

/// Lists all connected cameras and image devices on the Windows PC.
pub fn list_cameras() -> Vec<CameraDeviceInfo> {
    let script = r#"
        Get-CimInstance Win32_PnPEntity | Where-Object PNPClass -in 'Camera','Image' |
        Select-Object Name, DeviceID, Status | ConvertTo-Json -Compress
    "#;

    let mut cmd = Command::new("powershell");
    cmd.args(["-NoProfile", "-NonInteractive", "-Command", script]);
    cmd.creation_flags(CREATE_NO_WINDOW);

    let output = match cmd.output() {
        Ok(out) if out.status.success() => String::from_utf8_lossy(&out.stdout).to_string(),
        _ => return Vec::new(),
    };

    let trimmed = output.trim();
    if trimmed.is_empty() {
        return Vec::new();
    }

    let raw_list: Vec<RawDevice> = if trimmed.starts_with('[') {
        serde_json::from_str(trimmed).unwrap_or_default()
    } else if let Ok(single) = serde_json::from_str::<RawDevice>(trimmed) {
        vec![single]
    } else {
        Vec::new()
    };

    raw_list
        .into_iter()
        .map(|d| {
            let name = d.name.unwrap_or_else(|| "Kamera Tidak Dikenal".into());
            let dev_id = d.device_id.unwrap_or_default();
            let status = d.status.unwrap_or_else(|| "Unknown".into());

            let name_lower = name.to_lowercase();
            let id_lower = dev_id.to_lowercase();
            let is_webcam = name_lower.contains("camera")
                || name_lower.contains("webcam")
                || id_lower.contains("usb")
                || id_lower.contains("vid");

            CameraDeviceInfo {
                name,
                device_id: dev_id,
                status,
                is_webcam,
            }
        })
        .collect()
}

/// Captures a single photo from the primary webcam using Windows.Media.Capture.
/// Safely releases the hardware device immediately after the frame is captured.
pub fn capture_photo() -> Result<CameraSnapshot, String> {
    let script = r#"
try {
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    [Windows.Media.Capture.MediaCapture, Windows.Media, ContentType = WindowsRuntime] | Out-Null
    [Windows.Media.MediaProperties.ImageEncodingProperties, Windows.Media, ContentType = WindowsRuntime] | Out-Null
    [Windows.Storage.Streams.InMemoryRandomAccessStream, Windows.Storage.Streams, ContentType = WindowsRuntime] | Out-Null

    $asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { 
        $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' 
    })[0]

    $asTaskAction = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { 
        $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncAction' 
    })[0]

    function Await-Action($action) {
        $task = $asTaskAction.Invoke($null, @($action))
        $task.Wait(12000) | Out-Null
    }

    $mediaCapture = [Windows.Media.Capture.MediaCapture]::new()
    Await-Action ($mediaCapture.InitializeAsync())

    $encoding = [Windows.Media.MediaProperties.ImageEncodingProperties]::CreateJpeg()
    $stream = [Windows.Storage.Streams.InMemoryRandomAccessStream]::new()
    Await-Action ($mediaCapture.CapturePhotoToStreamAsync($encoding, $stream))

    $netStream = [System.IO.WindowsRuntimeStreamExtensions]::AsStream($stream)
    $bytes = [byte[]]::new($stream.Size)
    $netStream.Position = 0
    $netStream.Read($bytes, 0, $bytes.Length) | Out-Null

    $timestamp = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $tempFile = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "mochi_webcam_$timestamp.jpg")
    [System.IO.File]::WriteAllBytes($tempFile, $bytes)
    $mediaCapture.Dispose()

    $b64 = [Convert]::ToBase64String($bytes)

    [PSCustomObject]@{
        success = $true
        filePath = $tempFile
        sizeBytes = $bytes.Length
        base64Image = $b64
        error = ""
    } | ConvertTo-Json -Compress
} catch {
    [PSCustomObject]@{
        success = $false
        filePath = ""
        sizeBytes = 0
        base64Image = ""
        error = $_.ToString()
    } | ConvertTo-Json -Compress
}
"#;

    let mut cmd = Command::new("powershell");
    cmd.args(["-NoProfile", "-NonInteractive", "-Command", script]);
    cmd.creation_flags(CREATE_NO_WINDOW);

    let output = match cmd.output() {
        Ok(out) => String::from_utf8_lossy(&out.stdout).to_string(),
        Err(e) => return Err(format!("Gagal mengeksekusi pipeline kamera: {e}")),
    };

    let trimmed = output.trim();
    if trimmed.is_empty() {
        return Err("Tidak ada output yang diterima dari pipeline kamera.".into());
    }

    let parsed: RawCaptureResult = match serde_json::from_str(trimmed) {
        Ok(res) => res,
        Err(e) => return Err(format!("Gagal memproses respon capture kamera: {e} (output: {trimmed})")),
    };

    if !parsed.success {
        let err_msg = parsed.error.unwrap_or_else(|| "Gagal menginisialisasi kamera".into());
        return Err(format!("Akses kamera ditolak atau perangkat tidak siap: {err_msg}"));
    }

    let now = chrono_like_timestamp();
    let size_kb = parsed.size_bytes / 1024;
    let summary = format!(
        "### Foto Webcam Berhasil Diambil\n- **Lokasi Berkas:** `{}`\n- **Ukuran:** {} KB ({} bytes)\n- **Waktu:** {}\n- **Status Sensor:** Siap & sensor telah dinonaktifkan kembali (Privacy Protected)",
        parsed.file_path, size_kb, parsed.size_bytes, now
    );

    Ok(CameraSnapshot {
        file_path: parsed.file_path,
        size_bytes: parsed.size_bytes,
        base64_image: parsed.base64_image,
        timestamp: now,
        summary_markdown: summary,
    })
}

fn chrono_like_timestamp() -> String {
    let script = r#"[DateTime]::Now.ToString("yyyy-MM-dd HH:mm:ss")"#;
    let mut cmd = Command::new("powershell");
    cmd.args(["-NoProfile", "-NonInteractive", "-Command", script]);
    cmd.creation_flags(CREATE_NO_WINDOW);

    cmd.output()
        .ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "Just now".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn list_cameras_runs_without_panicking() {
        let cameras = list_cameras();
        // Just verify it returns without panic
        let _ = cameras.len();
    }
}

