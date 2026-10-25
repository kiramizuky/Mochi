import Foundation

// MARK: - SmartIntentRouterTests

final class MockLocalProvider: LLMProvider, @unchecked Sendable {
    let id = "local_mlx"
    let displayName = "Local MLX"
    let defaultModel = "qwen2.5:7b"
    let fallbackModels: [(id: String, label: String)] = [("qwen2.5:7b", "Qwen 2.5 7B")]

    func isConfigured() -> Bool { true }
    func listModels() async -> [(id: String, label: String)] { fallbackModels }
    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        LLMResponse(content: [.text("local response")], stopReason: .endTurn)
    }
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.completed(LLMResponse(content: [.text("local response")], stopReason: .endTurn)))
            continuation.finish()
        }
    }
}

final class MockCloudProvider: LLMProvider, @unchecked Sendable {
    let id = "mock_cloud"
    let displayName = "Mock Cloud"
    let defaultModel = "claude-sonnet-4-6"
    let fallbackModels: [(id: String, label: String)] = [("claude-sonnet-4-6", "Claude Sonnet 4.6")]

    func isConfigured() -> Bool { true }
    func listModels() async -> [(id: String, label: String)] { fallbackModels }
    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        LLMResponse(content: [.text("cloud response")], stopReason: .endTurn)
    }
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.completed(LLMResponse(content: [.text("cloud response")], stopReason: .endTurn)))
            continuation.finish()
        }
    }
}

@main enum SmartIntentRouterTests {
    static func main() async throws {
        testResolveTierOffline()
        testResolveTierSimpleRoutine()
        testResolveTierAutonomous()
        testResolveTierCloudLLM()
        testSelectExecutionWithLocalRegistered()
        testSelectExecutionDisabled()
        print("SmartIntentRouterTests: all cases passed")
    }
}

func testResolveTierOffline() {
    let router = SmartIntentRouter.shared
    precondition(router.resolveTier(for: "jalankan secara lokal ya") == .localSLM)
    precondition(router.resolveTier(for: "bisa bantu offline?") == .localSLM)
    precondition(router.resolveTier(for: "on-device inference") == .localSLM)
    precondition(router.resolveTier(for: "tolong proses tanpa internet") == .localSLM)
}

func testResolveTierSimpleRoutine() {
    let router = SmartIntentRouter.shared
    precondition(router.resolveTier(for: "buka aplikasi Safari") == .localSLM)
    precondition(router.resolveTier(for: "close app Chrome") == .localSLM)
    precondition(router.resolveTier(for: "cek kapasitas disk") == .localSLM)
    precondition(router.resolveTier(for: "ambil screenshot") == .localSLM)
    precondition(router.resolveTier(for: "atur volume") == .localSLM)
}

func testResolveTierAutonomous() {
    let router = SmartIntentRouter.shared
    precondition(router.resolveTier(for: "jadwalkan backup harian jam 8") == .autonomousWorkflow)
    precondition(router.resolveTier(for: "otomatiskan download invoice mingguan") == .autonomousWorkflow)
    precondition(router.resolveTier(for: "buatkan playbook untuk deploy") == .autonomousWorkflow)
    precondition(router.resolveTier(for: "selidiki dan buat laporan lengkap") == .autonomousWorkflow)
}

func testResolveTierCloudLLM() {
    let router = SmartIntentRouter.shared
    precondition(router.resolveTier(for: "analisis arsitektur sistem microservices dan buat rekomendasi perbaikan performa") == .cloudLLM)
    precondition(router.resolveTier(for: "tulis esai mendalam mengenai sejarah perkembangan kecerdasan buatan") == .cloudLLM)
    precondition(router.resolveTier(for: "refactor kode ini agar mengikuti prinsip SOLID dan clean architecture") == .cloudLLM)
}

func testSelectExecutionWithLocalRegistered() {
    let router = SmartIntentRouter.shared
    let local = MockLocalProvider()
    ProviderRegistry.shared.register(local)

    let cloud = MockCloudProvider()

    // Query lokal harus memilih local provider
    let resultLocal = router.selectExecution(for: "buka aplikasi Finder", activeProvider: cloud, activeModel: cloud.defaultModel)
    precondition(resultLocal.tier == .localSLM)
    precondition(resultLocal.provider.id == "local_mlx")
    precondition(resultLocal.model == "qwen2.5:7b")

    // Query analitis harus memilih cloud provider
    let resultCloud = router.selectExecution(
        for: "jelaskan perbandingan performa antara Swift concurrency dan Grand Central Dispatch",
        activeProvider: cloud,
        activeModel: cloud.defaultModel
    )
    precondition(resultCloud.tier == .cloudLLM)
    precondition(resultCloud.provider.id == cloud.id)
    precondition(resultCloud.model == cloud.defaultModel)
}

func testSelectExecutionDisabled() {
    let router = SmartIntentRouter.shared
    let cloud = MockCloudProvider()

    UserDefaults.standard.set(false, forKey: "smartIntentRoutingEnabled")
    defer { UserDefaults.standard.removeObject(forKey: "smartIntentRoutingEnabled") }

    let result = router.selectExecution(for: "buka aplikasi Safari", activeProvider: cloud, activeModel: cloud.defaultModel)
    precondition(result.tier == .cloudLLM)
    precondition(result.provider.id == cloud.id)
}

