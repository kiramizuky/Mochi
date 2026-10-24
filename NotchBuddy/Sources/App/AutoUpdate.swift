import Foundation
import AppKit
import CommonCrypto

// MARK: - Auto-update (cek versi dari GitHub release, unduh DMG, verifikasi SHA-256)

/// Informasi rilis terbaru dari GitHub.
struct AppRelease: Equatable, Sendable, Codable {
    var tagName: String
    var version: String {
        tagName.replacingOccurrences(of: "v", with: "")
    }
    var downloadURL: URL?
    var sha256: String?
    var notes: String?

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case assets
        case body
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tagName = try container.decode(String.self, forKey: .tagName)
        notes = try container.decodeIfPresent(String.self, forKey: .body)
        sha256 = nil
        downloadURL = nil
        if let assets = try? container.decode([ReleaseAsset].self, forKey: .assets) {
            let dmgAssets = assets.filter { $0.name.hasSuffix(".dmg") }
            if let first = dmgAssets.first {
                downloadURL = URL(string: first.browserDownloadURL)
                sha256 = first.sha256
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(tagName, forKey: .tagName)
        try container.encode(notes, forKey: .body)
        try container.encode([ReleaseAsset](), forKey: .assets)
    }

    init(tagName: String, downloadURL: URL?, sha256: String?, notes: String?) {
        self.tagName = tagName
        self.downloadURL = downloadURL
        self.sha256 = sha256
        self.notes = notes
    }
}

struct ReleaseAsset: Equatable, Sendable, Codable {
    var name: String
    var browserDownloadURL: String
    var sha256: String?

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        browserDownloadURL = try container.decode(String.self, forKey: .browserDownloadURL)
        sha256 = nil
    }
}

/// Klien auto-update Foundation-only: cek GitHub releases, unduh DMG, verifikasi SHA-256.
final class AutoUpdate: @unchecked Sendable {
    static let shared = AutoUpdate()
    private init() {}

    private let session = URLSession(configuration: .default)
    private let owner = "louisraille"
    private let repo = "coucou"

    /// Versi saat ini dari Info.plist (CFBundleShortVersionString).
    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    /// Cek apakah ada versi terbaru dari GitHub. Mengembalikan nil jika tidak ada update atau gagal.
    func checkForUpdates() async -> AppRelease? {
        guard let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest") else {
            return nil
        }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Coucou/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15

        guard let (data, response) = try? await session.data(for: req),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let release = try? JSONDecoder().decode(AppRelease.self, from: data) else {
            return nil
        }

        let current = currentVersion.split(separator: ".").compactMap { Int($0) }
        let remote = release.version.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(current.count, remote.count) {
            let c = i < current.count ? current[i] : 0
            let r = i < remote.count ? remote[i] : 0
            if r > c { return release }
            if r < c { return nil }
        }
        return nil
    }

    /// Unduh DMG ke temp folder, verifikasi SHA-256 jika tersedia, kembalikan path file.
    func downloadUpdate(_ release: AppRelease) async -> URL? {
        guard let url = release.downloadURL else { return nil }
        do {
            let (tempURL, _) = try await session.download(from: url)
            if let expected = release.sha256, !expected.isEmpty {
                guard let data = try? Data(contentsOf: tempURL) else { return nil }
                guard data.sha256Hex.lowercased() == expected.lowercased() else { return nil }
            }
            return tempURL
        } catch {
            return nil
        }
    }

    /// Pasang DMG: salin aplikasi ke /Applications lalu restart Coucou.
    func install(_ dmgURL: URL) {
        let fm = FileManager.default
        let dest = fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Coucou.app")
        try? fm.removeItem(at: dest)
        try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.copyItem(at: dmgURL, to: dest)

        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Coucou.app"))
        NSApplication.shared.terminate(nil)
    }
}

extension Data {
    var sha256Hex: String {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        self.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(buffer.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}
