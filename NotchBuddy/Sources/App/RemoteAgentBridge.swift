import Foundation

// MARK- Remote agent bridge — Coucou sebagai worker agen terdistribusi

/// Coucou dapat menjadi "worker" bagi agen pusat (cloud/lokal): menerima tugas
/// melalui stdio (JSON-RPC sederhana) atau pemanggilan langsung, mengeksekusinya
/// otonom tanpa klik, dan melaporkan hasil balik ke agen pusat.
///
/// Semua eksekusi melewati ToolExecutor → PolicyEngine → AuditLog, jadi hard floor
/// dan konsent tetap berlaku bahkan saat dipanggil agen eksternal.
final class RemoteAgentBridge: @unchecked Sendable {
    static let shared = RemoteAgentBridge()

    /// Menjalankan satu tugas (goal) dan mengembalikan hasil orkestrasi.
    /// Default mendelegasikan ke AgentOrchestrator.shared; dapat di-inject untuk tes.
    var runTask: @Sendable (String, String) async -> OrchestrationResult

    private var serverTask: Task<Void, Never>?

    init(runTask: @escaping @Sendable (String, String) async -> OrchestrationResult = { goal, model in
        await AgentOrchestrator.shared.run(goal: goal, model: model)
    }) {
        self.runTask = runTask
    }

    /// Terima satu tugas dari agen pusat, jalankan otonom, kembalikan hasil.
    func run(goal: String, model: String) async -> OrchestrationResult {
        await runTask(goal, model)
    }

    /// Jalankan tugas lalu lapor hasil ke URL agen pusat (HTTP POST).
    func runAndReport(goal: String, model: String, to reportURL: URL) async -> Bool {
        let result = await run(goal: goal, model: model)
        return await report(result: result, to: reportURL)
    }

    /// Laporan hasil ke agen pusat via HTTP POST.
    func report(result: OrchestrationResult, to url: URL) async -> Bool {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "success": result.success,
            "transcript": result.transcript,
            "results": result.results.map { r in
                ["role": r.role.rawValue, "goal": r.goal,
                 "output": r.output, "isError": r.isError]
            },
        ]
        request.httpBody = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode ?? 0 < 300
        } catch {
            return false
        }
    }

    /// Mulai mendengarkan stdin (JSON-RPC per baris) sebagai worker.
    /// Setiap baris: { "method": "runTask", "params": { "goal": "...", "model": "..." } }
    /// Balasan ditulis ke stdout sebagai satu baris JSON.
    func serveStdio() async {
        serverTask = Task { [weak self] in
            guard let self else { return }
            let stdin = FileHandle.standardInput
            let stdout = FileHandle.standardOutput
            do {
                for try await line in stdin.bytes.lines {
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }
                    guard let data = trimmed.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        continue
                    }
                    guard json["method"] as? String == "runTask",
                          let params = json["params"] as? [String: Any],
                          let goal = params["goal"] as? String else {
                        continue
                    }
                    let model = params["model"] as? String ?? "claude-sonnet-4-6"
                    let result = await self.run(goal: goal, model: model)
                    let response: [String: Any] = [
                        "success": result.success,
                        "transcript": result.transcript,
                    ]
                    if let out = (try? JSONSerialization.data(withJSONObject: response)),
                       let str = String(data: out, encoding: .utf8) {
                        stdout.write((str + "\n").data(using: .utf8) ?? Data())
                    }
                }
            } catch {
                // Stream selesai atau error baca — hentikan diam-diam.
            }
        }
    }

    /// Hentikan server stdio.
    func stop() {
        serverTask?.cancel()
        serverTask = nil
    }
}
