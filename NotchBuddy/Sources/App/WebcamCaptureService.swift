import Foundation
import AVFoundation
import AppKit
import Vision
import CoreMedia
import CoreVideo

// MARK: - Webcam Visual Perception & Recording (Paket 6 & Pembaruan Sistem)

public enum WebcamError: LocalizedError, Sendable {
    case permissionDenied
    case noCameraAvailable
    case sessionConfigurationFailed
    case captureFailed(String)
    case recordingFailed(String)

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
        case .recordingFailed(let reason):
            return "Gagal merekam video: \(reason)"
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

public struct WebcamVideoResult: Sendable {
    public let timestamp: Date
    public let filePath: String
    public let durationSeconds: Double
    public let fileSizeBytes: Int64
    public let width: Int
    public let height: Int
}

public final class WebcamCaptureService: @unchecked Sendable {
    public static let shared = WebcamCaptureService()

    private let captureQueue = DispatchQueue(label: "com.notchbuddy.webcam.queue", qos: .userInitiated)
    private let stateLock = NSLock()
    private var activeSession: AVCaptureSession?
    private var activeDelegate: (any AnyObject)?

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

    // MARK: - Capture Photo (High Reliability via Video Sample Buffer)

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
                appendAppLog("nb.log", "WebcamCapture: Menginisialisasi kamera \(device.localizedName)...")
                let session = AVCaptureSession()
                session.beginConfiguration()
                session.sessionPreset = .high

                guard let input = try? AVCaptureDeviceInput(device: device),
                      session.canAddInput(input) else {
                    continuation.resume(throwing: WebcamError.sessionConfigurationFailed)
                    return
                }
                session.addInput(input)

                let videoOutput = AVCaptureVideoDataOutput()
                videoOutput.alwaysDiscardsLateVideoFrames = true
                videoOutput.videoSettings = [
                    (kCVPixelBufferPixelFormatTypeKey as String): Int(kCVPixelFormatType_32BGRA)
                ]

                let gate = CompletionGate()

                var grabberRef: SingleFrameGrabber?
                let grabber = SingleFrameGrabber { result in
                    guard gate.tryComplete() else { return }
                    self.stateLock.lock()
                    self.activeDelegate = nil
                    self.activeSession = nil
                    self.stateLock.unlock()

                    DispatchQueue.global().async {
                        session.stopRunning()
                    }
                    continuation.resume(with: result)
                }
                grabberRef = grabber

                self.stateLock.lock()
                self.activeDelegate = grabber
                self.activeSession = session
                self.stateLock.unlock()

                let videoQueue = DispatchQueue(label: "com.notchbuddy.webcam.grabber", qos: .userInitiated)
                videoOutput.setSampleBufferDelegate(grabber, queue: videoQueue)

                guard session.canAddOutput(videoOutput) else {
                    self.stateLock.lock()
                    self.activeDelegate = nil
                    self.activeSession = nil
                    self.stateLock.unlock()
                    continuation.resume(throwing: WebcamError.sessionConfigurationFailed)
                    return
                }
                session.addOutput(videoOutput)
                session.commitConfiguration()

                session.startRunning()
                appendAppLog("nb.log", "WebcamCapture: Sesi kamera berjalan (running=\(session.isRunning)), menunggu frame...")

                // Fallback timeout pengaman 8 detik
                DispatchQueue.global().asyncAfter(deadline: .now() + 8.0) {
                    guard gate.tryComplete() else { return }
                    self.stateLock.lock()
                    self.activeDelegate = nil
                    self.activeSession = nil
                    self.stateLock.unlock()
                    grabberRef?.releaseSelf()

                    DispatchQueue.global().async {
                        session.stopRunning()
                    }
                    appendAppLog("nb.log", "WebcamCapture: Timeout 8 detik tercapai.")
                    continuation.resume(throwing: WebcamError.captureFailed("Waktu respons kamera habis (timeout)"))
                }
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
            let faceReq = VNDetectFaceRectanglesRequest()
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

        // Simpan ke Canvas Artifact
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

    // MARK: - Record Video (MP4 / H.264)

    public func recordVideo(durationSeconds: Double = 3.0) async throws -> WebcamVideoResult {
        let hasAuth = await checkAuthorization()
        guard hasAuth else {
            throw WebcamError.permissionDenied
        }

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified)
                ?? AVCaptureDevice.default(for: .video) else {
            throw WebcamError.noCameraAvailable
        }

        let clampedDuration = max(1.0, min(durationSeconds, 60.0))
        let outputUrl = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mochi_webcam_video_\(Int(Date().timeIntervalSince1970)).mp4")

        let (url, width, height): (URL, Int, Int) = try await withCheckedThrowingContinuation { continuation in
            captureQueue.async {
                let session = AVCaptureSession()
                session.beginConfiguration()
                session.sessionPreset = .high

                guard let input = try? AVCaptureDeviceInput(device: device),
                      session.canAddInput(input) else {
                    continuation.resume(throwing: WebcamError.sessionConfigurationFailed)
                    return
                }
                session.addInput(input)

                let videoOutput = AVCaptureVideoDataOutput()
                videoOutput.alwaysDiscardsLateVideoFrames = true
                videoOutput.videoSettings = [
                    (kCVPixelBufferPixelFormatTypeKey as String): Int(kCVPixelFormatType_32BGRA)
                ]

                let gate = CompletionGate()

                var recorderRef: VideoRecorderSession?
                let recorder = VideoRecorderSession(outputUrl: outputUrl, durationSeconds: clampedDuration) { result in
                    guard gate.tryComplete() else { return }
                    self.stateLock.lock()
                    self.activeDelegate = nil
                    self.activeSession = nil
                    self.stateLock.unlock()

                    DispatchQueue.global().async {
                        session.stopRunning()
                    }
                    continuation.resume(with: result)
                }
                recorderRef = recorder

                self.stateLock.lock()
                self.activeDelegate = recorder
                self.activeSession = session
                self.stateLock.unlock()

                let videoQueue = DispatchQueue(label: "com.notchbuddy.webcam.recorder", qos: .userInitiated)
                videoOutput.setSampleBufferDelegate(recorder, queue: videoQueue)

                guard session.canAddOutput(videoOutput) else {
                    self.stateLock.lock()
                    self.activeDelegate = nil
                    self.activeSession = nil
                    self.stateLock.unlock()
                    continuation.resume(throwing: WebcamError.sessionConfigurationFailed)
                    return
                }
                session.addOutput(videoOutput)
                session.commitConfiguration()

                session.startRunning()

                // Fallback timeout pengaman (durasi + 8 detik)
                DispatchQueue.global().asyncAfter(deadline: .now() + clampedDuration + 8.0) {
                    guard gate.tryComplete() else { return }
                    self.stateLock.lock()
                    self.activeDelegate = nil
                    self.activeSession = nil
                    self.stateLock.unlock()
                    recorderRef?.releaseSelf()

                    DispatchQueue.global().async {
                        session.stopRunning()
                    }
                    continuation.resume(throwing: WebcamError.recordingFailed("Waktu perekaman video habis (timeout)"))
                }
            }
        }

        let fileSizeBytes: Int64
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int64 {
            fileSizeBytes = size
        } else {
            fileSizeBytes = 0
        }

        // Publikasikan ke Canvas Artifact sebagai media video player
        let sizeFormatted = ByteCountFormatter.string(fromByteCount: fileSizeBytes, countStyle: .file)
        let artifact = CanvasArtifact(
            id: "video_\(Int(Date().timeIntervalSince1970))",
            title: "Video Webcam (\(String(format: "%.1f", clampedDuration))s)",
            type: .media,
            content: """
            # Rekaman Video Webcam MacBook
            - **Waktu**: \(Date().formatted())
            - **Durasi**: \(String(format: "%.1f", clampedDuration)) detik
            - **Resolusi**: \(width) x \(height) px
            - **Ukuran File**: \(sizeFormatted)
            - **Path File**: `\(url.path)`
            """,
            metadata: [
                "filePath": url.path,
                "mediaType": "video",
                "mimeType": "video/mp4"
            ]
        )
        Task { @MainActor in
            CanvasManager.shared.currentArtifact = artifact
        }

        return WebcamVideoResult(
            timestamp: Date(),
            filePath: url.path,
            durationSeconds: clampedDuration,
            fileSizeBytes: fileSizeBytes,
            width: width,
            height: height
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

// MARK: - Thread-Safe Completion Gate

private final class CompletionGate: @unchecked Sendable {
    private var isCompleted = false
    private let lock = NSLock()

    func tryComplete() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if isCompleted { return false }
        isCompleted = true
        return true
    }
}

// MARK: - Internal Single Frame Grabber Delegate

private final class SingleFrameGrabber: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private var selfRetain: SingleFrameGrabber?
    private let completion: @Sendable (Result<Data, Error>) -> Void
    private var framesReceived = 0
    private var isDone = false
    private let lock = NSLock()

    init(completion: @escaping @Sendable (Result<Data, Error>) -> Void) {
        self.completion = completion
        super.init()
        self.selfRetain = self
    }

    func releaseSelf() {
        lock.lock()
        defer { lock.unlock() }
        selfRetain = nil
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        lock.lock()
        defer { lock.unlock() }
        guard !isDone else { return }

        framesReceived += 1

        // Frame ke-2 sudah stabil exposure dan white balance di FaceTime HD camera
        if framesReceived >= 2 {
            isDone = true
            guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                completion(.failure(WebcamError.captureFailed("Gagal memperoleh image buffer dari kamera")))
                releaseSelf()
                return
            }

            let ciImage = CIImage(cvImageBuffer: imageBuffer)
            let rep = NSCIImageRep(ciImage: ciImage)
            let nsImage = NSImage(size: rep.size)
            nsImage.addRepresentation(rep)

            guard let tiffData = nsImage.tiffRepresentation,
                  let bitmapRep = NSBitmapImageRep(data: tiffData),
                  let jpegData = bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else {
                completion(.failure(WebcamError.captureFailed("Gagal mengonversi frame kamera ke format JPEG")))
                releaseSelf()
                return
            }

            completion(.success(jpegData))
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.releaseSelf()
            }
        }
    }
}

// MARK: - Internal Video Recorder Session

private final class VideoRecorderSession: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private var selfRetain: VideoRecorderSession?
    private var assetWriter: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var isRecording = false
    private var sessionStartTime: CMTime?
    private var frameCount = 0
    private let targetFrames: Int
    private let outputUrl: URL
    private var videoWidth = 0
    private var videoHeight = 0
    private let completion: @Sendable (Result<(URL, Int, Int), Error>) -> Void
    private let lock = NSLock()

    init(outputUrl: URL, durationSeconds: Double, completion: @escaping @Sendable (Result<(URL, Int, Int), Error>) -> Void) {
        self.outputUrl = outputUrl
        self.targetFrames = max(24, Int(durationSeconds * 24.0)) // Target 24 fps
        self.completion = completion
        super.init()
        self.selfRetain = self
    }

    func releaseSelf() {
        lock.lock()
        defer { lock.unlock() }
        selfRetain = nil
    }

    private func setupWriter(width: Int, height: Int) throws {
        if FileManager.default.fileExists(atPath: outputUrl.path) {
            try? FileManager.default.removeItem(at: outputUrl)
        }

        let writer = try AVAssetWriter(outputURL: outputUrl, fileType: .mp4)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ]

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = true

        let sourcePixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ]

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: sourcePixelBufferAttributes
        )

        guard writer.canAdd(input) else {
            throw WebcamError.recordingFailed("Tidak dapat menambahkan video input ke AVAssetWriter")
        }
        writer.add(input)

        self.assetWriter = writer
        self.writerInput = input
        self.pixelBufferAdaptor = adaptor
        self.videoWidth = width
        self.videoHeight = height

        guard writer.startWriting() else {
            throw WebcamError.recordingFailed(writer.error?.localizedDescription ?? "Gagal memulai AVAssetWriter")
        }
        self.isRecording = true
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        lock.lock()
        defer { lock.unlock() }

        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        if assetWriter == nil {
            let width = CVPixelBufferGetWidth(imageBuffer)
            let height = CVPixelBufferGetHeight(imageBuffer)
            do {
                try setupWriter(width: width, height: height)
            } catch {
                completion(.failure(error))
                isRecording = false
                releaseSelf()
                return
            }
        }

        guard isRecording,
              let writer = assetWriter,
              let input = writerInput,
              let adaptor = pixelBufferAdaptor else {
            return
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        if sessionStartTime == nil {
            writer.startSession(atSourceTime: pts)
            sessionStartTime = pts
        }

        if input.isReadyForMoreMediaData {
            if adaptor.append(imageBuffer, withPresentationTime: pts) {
                frameCount += 1
            }
        }

        if frameCount >= targetFrames {
            isRecording = false
            input.markAsFinished()
            let capturedWriter = writer
            let outUrl = outputUrl
            let w = videoWidth
            let h = videoHeight
            let comp = completion
            writer.finishWriting {
                if let error = capturedWriter.error {
                    comp(.failure(error))
                } else {
                    comp(.success((outUrl, w, h)))
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.releaseSelf()
                }
            }
        }
    }
}
