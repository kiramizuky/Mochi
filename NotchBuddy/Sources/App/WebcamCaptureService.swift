import Foundation
import AVFoundation
import AppKit
import Vision

// MARK: - Webcam Visual Perception (Paket 6)

public enum WebcamError: LocalizedError, Sendable {
    case permissionDenied
    case noCameraAvailable
    case sessionConfigurationFailed
    case captureFailed(String)

    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Izin kamera tidak diberikan. Silakan aktifkan di Pengaturan Sistem > Privasi & Keamanan > Kamera."
        case .noCameraAvailable:
            return "Tidak ada perangkat kamera yang terdeteksi di Mac ini."
        case .sessionConfigurationFailed:
            return "Gagal mengonfigurasi sesi penangkapan kamera."
        case .captureFailed(let reason):
            return "Gagal mengambil foto: \(reason)"
        }
    }
}

public struct WebcamCaptureResult: Sendable {
    public let timestamp: Date
    public let filePath: String
    public let data: Data
    public let width: Int
    public let height: Int
    public let detectedFacesCount: Int
    public let sceneClassifications: [String]
}

public final class WebcamCaptureService: @unchecked Sendable {
    public static let shared = WebcamCaptureService()

    private let captureQueue = DispatchQueue(label: "com.notchbuddy.webcam.queue", qos: .userInitiated)

    private init() {}

    // MARK: - Permissions

    public func checkAuthorization() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    // MARK: - Capture Photo

    public func capturePhoto() async throws -> WebcamCaptureResult {
        let hasAuth = await checkAuthorization()
        guard hasAuth else {
            throw WebcamError.permissionDenied
        }

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified)
                ?? AVCaptureDevice.default(for: .video) else {
            throw WebcamError.noCameraAvailable
        }

        let photoData: Data = try await withCheckedThrowingContinuation { continuation in
            captureQueue.async {
                let session = AVCaptureSession()
                session.beginConfiguration()
                session.sessionPreset = .photo

                guard let input = try? AVCaptureDeviceInput(device: device),
                      session.canAddInput(input) else {
                    continuation.resume(throwing: WebcamError.sessionConfigurationFailed)
                    return
                }
                session.addInput(input)

                let photoOutput = AVCapturePhotoOutput()
                guard session.canAddOutput(photoOutput) else {
                    continuation.resume(throwing: WebcamError.sessionConfigurationFailed)
                    return
                }
                session.addOutput(photoOutput)
                session.commitConfiguration()

                session.startRunning()

                let delegate = SinglePhotoCaptureDelegate { result in
                    session.stopRunning()
                    continuation.resume(with: result)
                }

                let settings = AVCapturePhotoSettings()
                photoOutput.capturePhoto(with: settings, delegate: delegate)
            }
        }

        // Simpan foto sementara ke /tmp
        let tempUrl = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mochi_webcam_\(Int(Date().timeIntervalSince1970)).jpg")
        try photoData.write(to: tempUrl)

        // Analisis cepat menggunakan Apple Vision on-device
        var width = 0
        var height = 0
        var faceCount = 0
        var classifications: [String] = []

        if let image = NSImage(data: photoData),
           let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            width = cgImage.width
            height = cgImage.height

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            
            // 1. Deteksi Wajah
            let faceReq = VNDetectFaceRectanglesRequest()
            // 2. Klasifikasi Pemandangan/Objek
            let classifyReq = VNClassifyImageRequest()

            try? handler.perform([faceReq, classifyReq])

            if let faces = faceReq.results {
                faceCount = faces.count
            }

            if let classificationsResults = classifyReq.results {
                classifications = classificationsResults
                    .filter { $0.confidence > 0.4 }
                    .prefix(5)
                    .map { $0.identifier.replacingOccurrences(of: "_", with: " ") }
            }
        }

        // Simpan ke Canvas Artifact agar pengguna dapat langsung membuka gambar di Canvas
        let artifact = CanvasArtifact(
            id: "webcam_\(Int(Date().timeIntervalSince1970))",
            title: "Foto Webcam (\(width)x\(height) px)",
            type: .document,
            content: """
            # Tangkapan Kamera MacBook
            - **Waktu**: \(Date().formatted())
            - **Path File**: `\(tempUrl.path)`
            - **Resolusi**: \(width) x \(height) px
            - **Wajah Terdeteksi**: \(faceCount)
            \(classifications.isEmpty ? "" : "- **Objek / Konteks**: " + classifications.joined(separator: ", "))

            ![Tangkapan Kamera](\(tempUrl.path))
            """,
            metadata: ["filePath": tempUrl.path]
        )
        Task { @MainActor in
            CanvasManager.shared.currentArtifact = artifact
        }

        return WebcamCaptureResult(
            timestamp: Date(),
            filePath: tempUrl.path,
            data: photoData,
            width: width,
            height: height,
            detectedFacesCount: faceCount,
            sceneClassifications: classifications
        )
    }

    // MARK: - Capture & Analyze (Multi-modal or Local Vision)

    public func captureAndAnalyze(prompt: String? = nil) async throws -> String {
        let result = try await capturePhoto()

        var report = """
        Foto Webcam Berhasil Ditangkap:
        • File: `\(result.filePath)`
        • Resolusi: \(result.width) x \(result.height) px
        • Jumlah Wajah Terdeteksi: \(result.detectedFacesCount)
        """

        if !result.sceneClassifications.isEmpty {
            report += "\n• Objek/Konteks Terdeteksi: \(result.sceneClassifications.joined(separator: ", "))"
        }

        if let userPrompt = prompt, !userPrompt.isEmpty {
            report += "\n\nPertanyaan/Permintaan Pengguna: \"\(userPrompt)\""
        }

        return report
    }
}

// MARK: - Internal Delegate Helper

private final class SinglePhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private let completion: @Sendable (Result<Data, Error>) -> Void
    private var didFinish = false
    private let lock = NSLock()

    init(completion: @escaping @Sendable (Result<Data, Error>) -> Void) {
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        lock.lock()
        defer { lock.unlock() }

        guard !didFinish else { return }
        didFinish = true

        if let error = error {
            completion(.failure(error))
            return
        }

        guard let data = photo.fileDataRepresentation() else {
            completion(.failure(WebcamError.captureFailed("Gagal mengonversi frame foto ke data biner")))
            return
        }

        completion(.success(data))
    }
}

