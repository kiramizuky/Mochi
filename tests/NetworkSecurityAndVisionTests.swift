import Foundation
import AppKit

@main
struct NetworkSecurityAndVisionTests {
    static func main() async throws {
        let err = FileHandle.standardError
        func log(_ s: String) { _ = err.write((s + "\n").data(using: .utf8)!) }

        log("🚀 Menjalankan NetworkSecurityAndVisionTests...")

        // T1: Network Security Audit
        log("T1: testNetworkSecurityAudit")
        let secReport = await NetworkSecurityService.shared.auditLaptopSecurity()
        guard secReport.healthScore >= 0 && secReport.healthScore <= 100 else {
            fatalError("Health score invalid: \(secReport.healthScore)")
        }
        guard !secReport.checks.isEmpty else {
            fatalError("Security checks list is empty")
        }
        guard !secReport.summaryMarkdown.isEmpty else {
            fatalError("Summary markdown is empty")
        }
        log("  Health score: \(secReport.healthScore)% with \(secReport.checks.count) checks")
        log("T1 OK ✅")

        // T2: Network Diagnostics
        log("T2: testNetworkDiagnostics")
        let diagReport = await NetworkSecurityService.shared.runDiagnostics(targetHost: "1.1.1.1")
        guard diagReport.dnsResolutionMs >= 0 else {
            fatalError("DNS resolution time is negative: \(diagReport.dnsResolutionMs)")
        }
        log("  DNS resolution time: \(String(format: "%.1f", diagReport.dnsResolutionMs)) ms")
        log("T2 OK ✅")

        // T3: CCTV Gateway Registry
        log("T3: testCCTVGatewayRegistry")
        let camId = "test_cam_\(UUID().uuidString.prefix(6))"
        let testCam = CCTVCameraConfig(
            id: camId,
            name: "Kamera Garasi Test",
            location: "Garasi Belakang",
            streamUrl: "rtsp://192.168.1.99:554/live",
            snapshotUrl: "http://192.168.1.99/snapshot.jpg"
        )
        CCTVGatewayService.shared.addOrUpdateCamera(testCam)

        let cameras = CCTVGatewayService.shared.listCameras()
        guard cameras.contains(where: { $0.id == camId }) else {
            fatalError("CCTV camera not found in registry")
        }

        let found = CCTVGatewayService.shared.findCamera(identifier: "Kamera Garasi Test")
        guard found?.id == camId else {
            fatalError("Failed to find CCTV camera by name")
        }

        CCTVGatewayService.shared.removeCamera(id: camId)
        let camerasAfter = CCTVGatewayService.shared.listCameras()
        guard !camerasAfter.contains(where: { $0.id == camId }) else {
            fatalError("CCTV camera was not removed from registry")
        }
        log("T3 OK ✅")

        // T4: Face Recognition Graceful Handling
        log("T4: testFaceRecognitionService")
        FaceRecognitionService.shared.resetOwnerFace()
        guard !FaceRecognitionService.shared.isOwnerEnrolled else {
            fatalError("Owner face should not be enrolled after reset")
        }

        // Test with invalid image data
        let dummyData = "not_an_image".data(using: .utf8)!
        let enrollRes = try await FaceRecognitionService.shared.enrollOwnerFace(imageData: dummyData)
        guard !enrollRes.isSuccess else {
            fatalError("Enrollment should fail gracefully on invalid data")
        }

        let verifyRes = try await FaceRecognitionService.shared.verifyFace(in: dummyData)
        guard !verifyRes.isOwnerPresent else {
            fatalError("Verification should fail gracefully on invalid data")
        }
        log("T4 OK ✅")

        // T5: ToolExecutor Tool Registration & Aliasing
        log("T5: testToolExecutorRegistrationAndResilience")
        let toolNames = Set(ToolExecutor.tools.map { $0.name })
        let expectedTools = [
            "laptop_security_audit",
            "network_scan_lan",
            "network_diagnostics",
            "camera_capture_photo",
            "camera_analyze",
            "face_enroll_owner",
            "face_verify_presence",
            "cctv_list_cameras",
            "cctv_get_snapshot",
            "cctv_add_camera",
        ]

        for expected in expectedTools {
            guard toolNames.contains(expected) else {
                fatalError("ToolExecutor missing registered tool: \(expected)")
            }
        }

        // Test Aliasing
        let aliasTarget = ToolExecutor.targetDescription(name: "check_security", input: .object([:]))
        guard aliasTarget == "security audit" else {
            fatalError("Tool alias check_security should map to security audit, got: \(aliasTarget)")
        }

        let executor = ToolExecutor()
        let cctvRes = await executor.execute(name: "cctv_list_cameras", input: .object([:]))
        guard !cctvRes.isError || cctvRes.output.contains("Belum ada kamera") || cctvRes.output.contains("Daftar Kamera") else {
            fatalError("cctv_list_cameras failed unexpectedly: \(cctvRes.output)")
        }

        log("T5 OK ✅")

        log("🎉 SEMUA TEST Network Security, Visual Perception, Face & CCTV LULUS!")
    }
}

