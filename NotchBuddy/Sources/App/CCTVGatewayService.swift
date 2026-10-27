import Foundation
import AppKit

// MARK: - CCTV RTSP & IoT Streamer (Paket 8)

public struct CCTVCameraConfig: Codable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var location: String
    public var streamUrl: String // RTSP / HTTP URL
    public var snapshotUrl: String? // Opsional direct HTTP JPEG snapshot URL
    public var username: String?
    public var password: String?

    public init(id: String = UUID().uuidString,
                name: String,
                location: String,
                streamUrl: String,
                snapshotUrl: String? = nil,
                username: String? = nil,
                password: String? = nil) {
        self.id = id
        self.name = name
        self.location = location
        self.streamUrl = streamUrl
        self.snapshotUrl = snapshotUrl
        self.username = username
        self.password = password
    }
}

public enum CCTVError: LocalizedError, Sendable {
    case cameraNotFound(String)
    case invalidURL
    case connectionFailed(String)
    case snapshotFailed(String)

    public var errorDescription: String? {
        switch self {
        case .cameraNotFound(let id):
            return "Kamera CCTV dengan ID/Nama '\(id)' tidak ditemukan."
        case .invalidURL:
            return "Format URL kamera CCTV tidak valid."
        case .connectionFailed(let reason):
            return "Gagal terhubung ke kamera CCTV: \(reason)"
        case .snapshotFailed(let reason):
            return "Gagal mengambil snapshot dari kamera CCTV: \(reason)"
        }
    }
}

public final class CCTVGatewayService: @unchecked Sendable {
    public static let shared = CCTVGatewayService()

    private let defaults = UserDefaults.standard
    private let storageKey = "mochi_cctv_configured_cameras"
    private let lock = NSLock()

    private init() {}

    // MARK: - Camera Registry Management

    public func listCameras() -> [CCTVCameraConfig] {
        lock.lock()
        defer { lock.unlock() }

        guard let data = defaults.data(forKey: storageKey),
              let list = try? JSONDecoder().decode([CCTVCameraConfig].self, from: data) else {
            return []
        }
        return list
    }

    public func addOrUpdateCamera(_ config: CCTVCameraConfig) {
        lock.lock()
        defer { lock.unlock() }

        var list: [CCTVCameraConfig] = []
        if let data = defaults.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode([CCTVCameraConfig].self, from: data) {
            list = saved
        }

        if let idx = list.firstIndex(where: { $0.id == config.id || $0.name.lowercased() == config.name.lowercased() }) {
            list[idx] = config
        } else {
            list.append(config)
        }

        if let encoded = try? JSONEncoder().encode(list) {
            defaults.set(encoded, forKey: storageKey)
        }
    }

    public func removeCamera(id: String) {
        lock.lock()
        defer { lock.unlock() }

        var list: [CCTVCameraConfig] = []
        if let data = defaults.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode([CCTVCameraConfig].self, from: data) {
            list = saved.filter { $0.id != id && $0.name.lowercased() != id.lowercased() }
            if let encoded = try? JSONEncoder().encode(list) {
                defaults.set(encoded, forKey: storageKey)
            }
        }
    }

    public func findCamera(identifier: String) -> CCTVCameraConfig? {
        let all = listCameras()
        let q = identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return all.first { $0.id == q || $0.name.lowercased() == q || $0.location.lowercased() == q }
    }

    // MARK: - Snapshot Capture

    public func captureSnapshot(cameraIdentifier: String) async throws -> (data: Data, filePath: String, summary: String) {
        let camera: CCTVCameraConfig
        if let found = findCamera(identifier: cameraIdentifier) {
            camera = found
        } else if cameraIdentifier.hasPrefix("http://") || cameraIdentifier.hasPrefix("https://") || cameraIdentifier.hasPrefix("rtsp://") {
            // Direct URL
            camera = CCTVCameraConfig(
                name: "Direct Camera",
                location: "Custom URL",
                streamUrl: cameraIdentifier,
                snapshotUrl: cameraIdentifier.hasPrefix("http") ? cameraIdentifier : nil
            )
        } else {
            throw CCTVError.cameraNotFound(cameraIdentifier)
        }

        let targetUrlStr = camera.snapshotUrl ?? camera.streamUrl
        guard let url = URL(string: targetUrlStr) else {
            throw CCTVError.invalidURL
        }

        var photoData: Data? = nil

        if url.scheme == "http" || url.scheme == "https" {
            // HTTP / HTTPS JPEG Snapshot Poller
            var request = URLRequest(url: url, timeoutInterval: 5.0)
            if let user = camera.username, let pass = camera.password {
                let authStr = "\(user):\(pass)"
                if let authData = authStr.data(using: .utf8) {
                    request.setValue("Basic \(authData.base64EncodedString())", forHTTPHeaderField: "Authorization")
                }
            }

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                if let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200, !data.isEmpty {
                    photoData = data
                } else {
                    throw CCTVError.snapshotFailed("HTTP status code: \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                }
            } catch {
                throw CCTVError.connectionFailed(error.localizedDescription)
            }
        } else if url.scheme == "rtsp" {
            // RTSP Stream Grabber (via ffmpeg jika tersedia di sistem, atau curl fallback)
            let tempOut = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cctv_rtsp_\(Int(Date().timeIntervalSince1970)).jpg")
            let ffmpegPath = "/opt/homebrew/bin/ffmpeg"
            let usrFfmpegPath = "/usr/local/bin/ffmpeg"
            let bin = FileManager.default.fileExists(atPath: ffmpegPath) ? ffmpegPath :
                      (FileManager.default.fileExists(atPath: usrFfmpegPath) ? usrFfmpegPath : nil)

            if let bin = bin {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: bin)
                process.arguments = [
                    "-y",
                    "-rtsp_transport", "tcp",
                    "-i", camera.streamUrl,
                    "-frames:v", "1",
                    "-q:v", "2",
                    tempOut.path
                ]
                try? process.run()
                process.waitUntilExit()

                if FileManager.default.fileExists(atPath: tempOut.path),
                   let data = try? Data(contentsOf: tempOut) {
                    photoData = data
                }
            }

            if photoData == nil {
                throw CCTVError.snapshotFailed("RTSP stream membutuhkan direct snapshot URL (HTTP) atau binary ffmpeg di /opt/homebrew/bin/ffmpeg.")
            }
        }

        guard let finalData = photoData else {
            throw CCTVError.snapshotFailed("Tidak menerima data frame dari kamera.")
        }

        let saveUrl = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cctv_\(camera.id)_\(Int(Date().timeIntervalSince1970)).jpg")
        try finalData.write(to: saveUrl)

        // Tampilkan di Canvas
        let artifact = CanvasArtifact(
            id: "cctv_\(camera.id)_\(Int(Date().timeIntervalSince1970))",
            title: "Snapshot CCTV: \(camera.name) (\(camera.location))",
            type: .document,
            content: """
            # Snapshot CCTV: \(camera.name)
            - **Lokasi**: \(camera.location)
            - **Waktu**: \(Date())
            - **File Path**: `\(saveUrl.path)`
            - **Ukuran File**: \(finalData.count / 1024) KB
            """
        )
        await MainActor.run {
            CanvasManager.shared.currentArtifact = artifact
        }

        let summary = """
        Snapshot CCTV Berhasil Diambil:
        • Nama Kamera: \(camera.name) (\(camera.location))
        • File Path: `\(saveUrl.path)`
        • Ukuran Frame: \(finalData.count / 1024) KB
        • Tampilan telah dimuat ke jendela Canvas Mochi.
        """

        return (finalData, saveUrl.path, summary)
    }
}
