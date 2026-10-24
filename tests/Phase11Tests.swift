import Foundation

// MARK: - Phase 11: Profesional & Rilis (auto-update, crash reporter, enterprise)

@main enum Phase11Tests {
    static func main() async throws {
        testDataSha256Hex()
        testCrashReporterRecordAndClear()
        testPolicyEngineAutopilotToggle()
        testAppReleaseParsing()
        print("Phase11Tests: all cases passed")
    }
}

// MARK: - Data.sha256Hex

func testDataSha256Hex() {
    let data = Data("hello".utf8)
    let hash = data.sha256Hex
    precondition(hash.count == 64, "sha256 hex length should be 64, got \(hash.count)")
    precondition(hash.allSatisfy { "0123456789abcdef".contains($0) })
    precondition(!hash.isEmpty)
    // Empty data hash.
    precondition(Data().sha256Hex == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
                 "empty hash mismatch: \(Data().sha256Hex)")
}

// MARK: - CrashReporter

func testCrashReporterRecordAndClear() {
    let crash = CrashReporter.shared
    crash.clear()
    crash.record(exception: NSException(
        name: NSExceptionName("TestException"),
        reason: "test reason",
        userInfo: nil))
    let reports = crash.all
    precondition(reports.count == 1, "expected 1 report, got \(reports.count)")
    precondition(reports[0].exception == "TestException")
    precondition(reports[0].reason == "test reason")
    precondition(!reports[0].timestamp.isEmpty)

    crash.clear()
    precondition(crash.all.isEmpty, "crash reports should be empty after clear")
}

// MARK: - PolicyEngine autopilot toggle

func testPolicyEngineAutopilotToggle() {
    // Default: shell/email/network autopilot, fileWrite/appControl askOnce.
    precondition(PolicyEngine.defaultModes[.shell] == .autopilot)
    precondition(PolicyEngine.defaultModes[.fileWrite] == .askOnce)

    // Simulasi matikan autopilot → semua askOnce.
    PolicyEngine.defaultModes[.shell] = .askOnce
    PolicyEngine.defaultModes[.email] = .askOnce
    PolicyEngine.defaultModes[.network] = .askOnce
    precondition(PolicyEngine.defaultModes[.shell] == PolicyMode.askOnce)
    precondition(PolicyEngine.defaultModes[.network] == PolicyMode.askOnce)

    // Kembalikan ke autopilot.
    PolicyEngine.defaultModes[.shell] = .autopilot
    PolicyEngine.defaultModes[.email] = .autopilot
    PolicyEngine.defaultModes[.network] = .autopilot
    PolicyEngine.defaultModes[.fileWrite] = .askOnce
    PolicyEngine.defaultModes[.appControl] = .askOnce
    precondition(PolicyEngine.defaultModes[.shell] == PolicyMode.autopilot)
    precondition(PolicyEngine.defaultModes[.fileWrite] == PolicyMode.askOnce)
}

// MARK: - AppRelease parsing

func testAppReleaseParsing() {
    let json = """
    {
      "tag_name": "v1.2.3",
      "body": "Fix bugs.",
      "assets": [
        { "name": "Coucou.dmg", "browser_download_url": "https://example.com/Coucou.dmg" }
      ]
    }
    """.data(using: .utf8)!
    let release = try! JSONDecoder().decode(AppRelease.self, from: json)
    precondition(release.tagName == "v1.2.3")
    precondition(release.version == "1.2.3")
    precondition(release.downloadURL?.absoluteString == "https://example.com/Coucou.dmg")
    precondition(release.notes == "Fix bugs.")
}
