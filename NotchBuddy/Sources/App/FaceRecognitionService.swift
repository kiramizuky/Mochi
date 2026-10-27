import Foundation
import Vision
import AppKit

// MARK: - On-Device Face Recognition & Presence Guard (Paket 7)

public struct FaceLandmarkProfile: Codable, Sendable {
    public let pupilDistanceRatio: Double
    public let eyeToNoseRatio: Double
    public let noseToMouthRatio: Double
}

public struct FaceVerificationResult: Sendable {
    public let isOwnerPresent: Bool
    public let confidenceScore: Double
    public let totalFacesDetected: Int
    public let isPeekingDetected: Bool
    public let message: String
}

public struct FaceEnrollmentResult: Sendable {
    public let isSuccess: Bool
    public let qualityScore: Float
    public let message: String
}

public final class FaceRecognitionService: @unchecked Sendable {
    public static let shared = FaceRecognitionService()

    private let defaults = UserDefaults.standard
    private let ownerFeaturePrintKey = "mochi_owner_face_feature_print"
    private let ownerEnrolledDateKey = "mochi_owner_face_enrolled_date"

    private init() {}

    public var isOwnerEnrolled: Bool {
        defaults.data(forKey: ownerFeaturePrintKey) != nil
    }

    public var enrolledDate: Date? {
        defaults.object(forKey: ownerEnrolledDateKey) as? Date
    }

    // MARK: - Enrolling Owner Face

    public func enrollOwnerFace(imageData: Data) async throws -> FaceEnrollmentResult {
        guard let image = NSImage(data: imageData),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return FaceEnrollmentResult(isSuccess: false, qualityScore: 0, message: "Format gambar tidak valid.")
        }

        let faceRectsReq = VNDetectFaceRectanglesRequest()
        let faceQualityReq = VNDetectFaceCaptureQualityRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        try handler.perform([faceRectsReq, faceQualityReq])

        guard let faces = faceRectsReq.results, !faces.isEmpty else {
            return FaceEnrollmentResult(isSuccess: false, qualityScore: 0, message: "Tidak ada wajah yang terdeteksi dalam foto. Pastikan pencahayaan cukup dan wajah menghadap kamera.")
        }

        if faces.count > 1 {
            return FaceEnrollmentResult(isSuccess: false, qualityScore: 0, message: "Terdeteksi \(faces.count) wajah dalam foto. Pastikan hanya ada Anda sendiri di depan kamera saat registrasi.")
        }

        let primaryFace = faces[0]
        let qualityScore = primaryFace.faceCaptureQuality ?? 0.5

        // Ekstrak cropped face CGImage untuk feature print
        guard let croppedFaceCG = cropFace(from: cgImage, boundingBox: primaryFace.boundingBox) else {
            return FaceEnrollmentResult(isSuccess: false, qualityScore: qualityScore, message: "Gagal memotong area wajah.")
        }

        // Generate Image Feature Print
        let featurePrintReq = VNGenerateImageFeaturePrintRequest()
        let cropHandler = VNImageRequestHandler(cgImage: croppedFaceCG, options: [:])
        try cropHandler.perform([featurePrintReq])

        guard let printObs = featurePrintReq.results?.first as? VNFeaturePrintObservation else {
            return FaceEnrollmentResult(isSuccess: false, qualityScore: qualityScore, message: "Gagal membuat sidik wajah (feature print).")
        }

        // Simpan ke UserDefaults
        let archivedData = try NSKeyedArchiver.archivedData(withRootObject: printObs, requiringSecureCoding: true)
        defaults.set(archivedData, forKey: ownerFeaturePrintKey)
        defaults.set(Date(), forKey: ownerEnrolledDateKey)

        return FaceEnrollmentResult(
            isSuccess: true,
            qualityScore: qualityScore,
            message: "Wajah pemilik berhasil diregistrasikan dengan skor kualitas \(String(format: "%.0f%%", qualityScore * 100))."
        )
    }

    // MARK: - Remove Enrollment

    public func resetOwnerFace() {
        defaults.removeObject(forKey: ownerFeaturePrintKey)
        defaults.removeObject(forKey: ownerEnrolledDateKey)
    }

    // MARK: - Verifying Presence & Detecting Peeking

    public func verifyFace(in imageData: Data) async throws -> FaceVerificationResult {
        guard let image = NSImage(data: imageData),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return FaceVerificationResult(
                isOwnerPresent: false,
                confidenceScore: 0,
                totalFacesDetected: 0,
                isPeekingDetected: false,
                message: "Format gambar tidak valid."
            )
        }

        let faceRectsReq = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([faceRectsReq])

        let faces = faceRectsReq.results ?? []
        let totalCount = faces.count

        if totalCount == 0 {
            return FaceVerificationResult(
                isOwnerPresent: false,
                confidenceScore: 0,
                totalFacesDetected: 0,
                isPeekingDetected: false,
                message: "Tidak ada wajah di depan kamera (Pengguna Tidak Ditempat)."
            )
        }

        let isPeeking = totalCount > 1

        // Ambil enrolled feature print
        guard let savedData = defaults.data(forKey: ownerFeaturePrintKey),
              let enrolledPrint = try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: savedData) else {
            // Belum ada registrasi wajah, hanya bisa melaporkan deteksi wajah
            return FaceVerificationResult(
                isOwnerPresent: true,
                confidenceScore: 0.5,
                totalFacesDetected: totalCount,
                isPeekingDetected: isPeeking,
                message: "Terdeteksi \(totalCount) wajah, namun wajah pemilik belum diregistrasikan di Pengaturan."
            )
        }

        var highestConfidence: Double = 0.0
        var matched = false

        for face in faces {
            guard let croppedFaceCG = cropFace(from: cgImage, boundingBox: face.boundingBox) else {
                continue
            }

            let featurePrintReq = VNGenerateImageFeaturePrintRequest()
            let cropHandler = VNImageRequestHandler(cgImage: croppedFaceCG, options: [:])
            try? cropHandler.perform([featurePrintReq])

            if let currentPrint = featurePrintReq.results?.first as? VNFeaturePrintObservation {
                var distance: Float = 1.0
                try? currentPrint.computeDistance(&distance, to: enrolledPrint)
                
                // Jarak < 0.5 menandakan kecocokan tinggi (semakin kecil semakin cocok)
                let confidence = max(0.0, min(1.0, Double(1.0 - distance)))
                if confidence > highestConfidence {
                    highestConfidence = confidence
                }

                if distance < 0.45 {
                    matched = true
                }
            }
        }

        var message = ""
        if matched {
            message = "Wajah pemilik terverifikasi (Kecocokan: \(String(format: "%.0f%%", highestConfidence * 100)))."
        } else {
            message = "Wajah tidak cocok dengan data pemilik terdaftar."
        }

        if isPeeking {
            message += " ⚠️ PERINGATAN: Terdeteksi \(totalCount) orang di depan layar! Potensi pengintip layar."
        }

        return FaceVerificationResult(
            isOwnerPresent: matched,
            confidenceScore: highestConfidence,
            totalFacesDetected: totalCount,
            isPeekingDetected: isPeeking,
            message: message
        )
    }

    // MARK: - Helper Crop Face

    private func cropFace(from cgImage: CGImage, boundingBox: CGRect) -> CGImage? {
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)

        // Vision coordinates: origin di kiri bawah (0,0), normalized 0.0 - 1.0
        let rect = CGRect(
            x: boundingBox.origin.x * width,
            y: (1.0 - boundingBox.origin.y - boundingBox.size.height) * height,
            width: boundingBox.size.width * width,
            height: boundingBox.size.height * height
        )

        // Beri margin 15% jika memungkinkan
        let insetRect = rect.insetBy(dx: -rect.width * 0.15, dy: -rect.height * 0.15)
        let safeRect = insetRect.intersection(CGRect(x: 0, y: 0, width: width, height: height))

        return cgImage.cropping(to: safeRect)
    }
}

