import Foundation

@main
enum VoiceTests {
    static func main() {
        // MARK: VoiceText.speechText
        precondition(VoiceText.speechText(from: "**Hello** world") == "Hello world")
        precondition(VoiceText.speechText(from: "```swift\nlet a = 1\n``` done") == "done")
        precondition(VoiceText.speechText(from: "text ```unclosed") == "text")
        precondition(
            VoiceText.speechText(from: "![diagram](http://x/y.png) shows [docs](http://d)")
                == "diagram shows docs"
        )
        precondition(
            VoiceText.speechText(from: "# Title\n- item one\n- item two")
                == "Title item one item two"
        )
        precondition(
            VoiceText.speechText(from: "1. first\n2. second") == "first second"
        )
        precondition(VoiceText.speechText(from: "a `code` and *em* and ~~x~~")
                         == "a code and em and x")
        precondition(VoiceText.speechText(from: "") == "")
        precondition(VoiceText.speechText(from: "   \n\t  ") == "")

        let long = VoiceText.speechText(from: String(repeating: "word ", count: 300))
        precondition(long.count <= 701, "cap must hold near maxLength")
        precondition(long.hasSuffix("…"), "over-long text must end with ellipsis")
        let short = VoiceText.speechText(from: "tiny", maxLength: 700)
        precondition(short == "tiny", "short text untouched by cap")

        // MARK: VoiceText.spokenResponse
        precondition(
            VoiceText.spokenResponse(from: "Berikut kodenya:\n```python\nprint('halo')\n```\nSangat mudah.")
                == "Berikut kodenya: Sangat mudah."
        )
        precondition(
            VoiceText.spokenResponse(from: "Silakan buka https://apple.com untuk melihat.")
                == "Silakan buka tautan terkait untuk melihat."
        )
        precondition(
            VoiceText.spokenResponse(from: "→ app_open https://id.wikipedia.org/wiki/AI: Opened URL")
                == "Berhasil membuka halaman Wikipedia untuk Anda."
        )
        precondition(
            VoiceText.spokenResponse(from: "→ app_open https://id.wikipedia.org: Opened URL\nHalaman sudah saya buka.")
                == "Halaman sudah saya buka."
        )

        // MARK: VoiceText.containsWakeWord
        precondition(VoiceText.containsWakeWord("Hey Mochi!"))
        precondition(VoiceText.containsWakeWord("hey mochi"))
        precondition(VoiceText.containsWakeWord("MOCHÎ arrive"), "diacritics must fold")
        precondition(!VoiceText.containsWakeWord("nothing here"), "no false positive")
        precondition(!VoiceText.containsWakeWord("mojito"))
        precondition(VoiceText.containsWakeWord("Run JARVIS now", word: "jarvis"))
        precondition(!VoiceText.containsWakeWord("hello world", word: "jarvis"))

        // MARK: VoiceText.extractCommand
        precondition(VoiceText.extractCommand(from: "Mochi, tolong buka Safari") == "tolong buka Safari")
        precondition(VoiceText.extractCommand(from: "Jarvis: carikan artikel AI") == "carikan artikel AI")
        precondition(VoiceText.extractCommand(from: "Mochi") == nil)
        precondition(VoiceText.extractCommand(from: "Hey Mochi!") == nil)

        // MARK: VoiceText.isSentenceIncomplete
        precondition(VoiceText.isSentenceIncomplete("Tolong carikan informasi tentang") == true)
        precondition(VoiceText.isSentenceIncomplete("Buka Wikipedia tentang") == true)
        precondition(VoiceText.isSentenceIncomplete("Buka Wikipedia tentang AI") == false)
        precondition(VoiceText.isSentenceIncomplete("Buka Safari") == false)
        precondition(VoiceText.isSentenceIncomplete("dan") == true)

        // MARK: VoiceText.finalizeTranscript
        precondition(VoiceText.finalizeTranscript("  hello  ") == "hello")
        precondition(VoiceText.finalizeTranscript(" \n\t ") == nil, "whitespace-only → nil")
        precondition(VoiceText.finalizeTranscript("") == nil)

        // MARK: PTTReducer — happy path
        var s: PTTStatus = .idle
        s = PTTReducer.reduce(s, .press)
        precondition(s == .requesting, "idle+press → requesting")
        s = PTTReducer.reduce(s, .permissionsGranted)
        precondition(s == .listening, "requesting+granted → listening")
        s = PTTReducer.reduce(s, .transcriptFinal("hi"))
        precondition(s == .idle, "listening+final → idle")

        // Repeat press is a no-op (mic hold fires onChanged repeatedly).
        precondition(PTTReducer.reduce(.requesting, .press) == .requesting)
        precondition(PTTReducer.reduce(.listening, .press) == .listening)

        // Permission denied, then retry.
        precondition(PTTReducer.reduce(.requesting, .permissionsDenied) == .denied)
        precondition(PTTReducer.reduce(.denied, .press) == .requesting)

        // Audio error, then retry from failed state.
        precondition(PTTReducer.reduce(.listening, .audioError("boom")) == .failed("boom"))
        precondition(PTTReducer.reduce(.failed("boom"), .press) == .requesting)

        // Release while listening / while the permission dialog is up.
        precondition(PTTReducer.reduce(.listening, .release) == .idle)
        precondition(PTTReducer.reduce(.requesting, .release) == .idle,
                     "release during permission dialog → idle")

        // Late async events must never corrupt the state.
        precondition(PTTReducer.reduce(.idle, .transcriptFinal("late")) == .idle)
        precondition(PTTReducer.reduce(.idle, .audioError("late")) == .idle)
        precondition(PTTReducer.reduce(.listening, .permissionsGranted) == .listening)
        precondition(PTTReducer.reduce(.denied, .reset) == .idle)

        print("Voice core: 37 cases passed")
    }
}
