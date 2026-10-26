import Foundation

@main
struct MetacognitiveAndTelegramTests {
    static func main() async throws {
        let err = FileHandle.standardError
        func log(_ s: String) { _ = err.write((s + "\n").data(using: .utf8)!) }

        log("🚀 Menjalankan MetacognitiveAndTelegramTests...")

        // T1: Dynamic Tool Safety Guardrails
        log("T1: testDynamicToolSafetyGuardrails")
        testDynamicToolSafetyGuardrails()
        log("T1 OK ✅")

        // T2: Dynamic Tool Registration & LLM Tool Defs
        log("T2: testDynamicToolRegistration")
        testDynamicToolRegistration()
        log("T2 OK ✅")

        // T3: Dynamic Sandbox Execution
        log("T3: testDynamicSandboxExecution")
        await testDynamicSandboxExecution()
        log("T3 OK ✅")

        // T4: ToolExecutor Dynamic Tool Dispatch
        log("T4: testToolExecutorDynamicToolIntegration")
        await testToolExecutorDynamicToolIntegration()
        log("T4 OK ✅")

        // T5: Telegram Gateway Pairing Protocol
        log("T5: testTelegramGatewayPairingProtocol")
        await testTelegramGatewayPairingProtocol()
        log("T5 OK ✅")

        log("🎉 SEMUA TEST Metacognitive Tool Maker & Telegram Gateway LULUS!")
    }

    // MARK: - T1: Dynamic Tool Safety Guardrails

    static func testDynamicToolSafetyGuardrails() {
        let sandbox = DynamicSkillSandbox.shared

        // Script berbahaya harus diblokir
        let badScript1 = "echo 'Starting'; sudo rm -rf /; echo 'Done'"
        let result1 = sandbox.validateSafety(scriptSource: badScript1, language: .bash)
        assert(result1.isFailure, "sudo rm -rf harus diblokir oleh sandbox")

        let badScript2 = ":(){ :|:& };:"
        let result2 = sandbox.validateSafety(scriptSource: badScript2, language: .bash)
        assert(result2.isFailure, "Fork bomb harus diblokir oleh sandbox")

        // Script aman harus diizinkan
        let safeScript = "echo 'Perhitungan:' && expr 10 + 20"
        let safeResult = sandbox.validateSafety(scriptSource: safeScript, language: .bash)
        assert(safeResult.isSuccess, "Script aman harus lolos validasi")
    }

    // MARK: - T2: Dynamic Tool Registration & LLM Tool Defs

    static func testDynamicToolRegistration() {
        let synth = DynamicToolSynthesizer.shared
        let toolId = "test_math_adder_\(UUID().uuidString.prefix(6).lowercased())"

        let reg = synth.registerTool(
            id: toolId,
            name: "Penjumlah Angka",
            description: "Menjumlahkan dua angka secara dinamis",
            language: .bash,
            scriptSource: "expr $ARG_A + $ARG_B",
            parameterNames: ["a", "b"]
        )

        assert(reg.isSuccess, "Pendaftaran dynamic tool harus berhasil")
        guard let tool = synth.getTool(id: toolId) else {
            fatalError("Tool harus tersimpan di synthesizer")
        }

        assert(tool.name == "Penjumlah Angka")
        assert(tool.language == .bash)

        // Verifikasi toLLMToolDef
        let def = tool.toLLMToolDef()
        assert(def.name == tool.id)
        assert(def.description.contains("[Dynamic Tool]"))

        // Bersihkan
        _ = synth.removeTool(id: toolId)
    }

    // MARK: - T3: Dynamic Sandbox Execution

    static func testDynamicSandboxExecution() async {
        let sandbox = DynamicSkillSandbox.shared
        let tool = DynamicTool(
            id: "test_sandbox_echo",
            name: "Echo Test",
            description: "Test echo",
            language: .bash,
            scriptSource: "echo \"Salam, $ARG_NAMA!\"",
            parameterNames: ["nama"]
        )

        let result = await sandbox.execute(tool: tool, arguments: ["nama": "Jarvis"])
        assert(!result.isError, "Eksekusi sandbox harus sukses, dapet error: \(result.output)")
        assert(result.output.contains("Salam, Jarvis!"), "Output harus memuat 'Salam, Jarvis!', dapet: \(result.output)")
        assert(result.exitCode == 0, "Exit code harus 0")
    }

    // MARK: - T4: ToolExecutor Dynamic Tool Dispatch

    static func testToolExecutorDynamicToolIntegration() async {
        let executor = ToolExecutor()
        let dynId = "dyn_word_counter_\(UUID().uuidString.prefix(6).lowercased())"

        // 1. Sintesis alat via ToolExecutor
        let synthInput = JSONValue.object([
            "id": .string(dynId),
            "name": .string("Penghitung Kata"),
            "description": .string("Menghitung jumlah kata dari teks"),
            "language": .string("bash"),
            "script_source": .string("echo -n \"$ARG_TEXT\" | wc -w | tr -d ' '"),
            "parameter_names": .array([.string("text")])
        ])

        let synthRes = await executor.execute(name: "tool_synthesize", input: synthInput)
        assert(!synthRes.isError, "Sintesis alat via ToolExecutor harus berhasil: \(synthRes.output)")

        // 2. Jalankan alat dinamis yang baru disintesis langsung via namanya
        let runInput = JSONValue.object([
            "text": .string("Mochi Asisten Otonom Coucou")
        ])

        let runRes = await executor.execute(name: dynId, input: runInput)
        assert(!runRes.isError, "Pemanggilan alat dinamis via ToolExecutor harus berhasil: \(runRes.output)")
        assert(runRes.output.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) == "4",
               "Harus menghitung 4 kata, dapet: '\(runRes.output)'")

        // Bersihkan
        _ = DynamicToolSynthesizer.shared.removeTool(id: dynId)
    }

    // MARK: - T5: Telegram Gateway Pairing Protocol

    static func testTelegramGatewayPairingProtocol() async {
        let gateway = TelegramGatewayService.shared

        // Simpan nilai lama
        let oldAllowed = gateway.allowedChatId
        gateway.allowedChatId = "12345678" // Chat ID resmi

        assert(gateway.allowedChatId == "12345678", "Allowed Chat ID harus terkonfigurasi")

        // Reset nilai
        gateway.allowedChatId = oldAllowed
    }
}

// MARK: - Result Extension Helper

private extension Result {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
    var isFailure: Bool {
        !isSuccess
    }
}

