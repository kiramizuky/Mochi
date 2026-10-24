import Foundation

// MARK- Fase 13.4: Proaktif Prediktif — HabitLearner + chip kebiasaan di ProactiveEngine

@main enum Phase14Tests {
    static func main() async throws {
        testHabitLearnerRecordAndCount()
        testHabitLearnerSuggestionsEmptyBelowThreshold()
        testHabitLearnerSuggestionsDetectsRoutine()
        testHabitLearnerSortedByConfidence()
        testHabitLearnerMinConfidenceFilter()
        testHabitLearnerNowInjection()
        testProactiveEngineIncludesHabitChips()
        testProactiveEngineRecordHabitDelegates()
        print("Phase14Tests: all cases passed")
    }
}

// MARK- HabitLearner

func testHabitLearnerRecordAndCount() {
    let learner = HabitLearner()
    learner.now = { Date(timeIntervalSince1970: 1_700_000_000) } // fixed
    learner.clear()
    precondition(learner.count == 0, "count harusnya 0 pada awal")
    learner.record(action: "buka Mail", category: "app")
    learner.record(action: "buka Mail", category: "app")
    precondition(learner.count == 2, "count harusnya 2, dapet \(learner.count)")
}

func testHabitLearnerSuggestionsEmptyBelowThreshold() {
    let learner = HabitLearner()
    learner.now = { Date(timeIntervalSince1970: 1_700_000_000) }
    learner.clear()
    // 2 kali kemunculan < 3 → tidak ada saran
    learner.record(action: "buka Mail", category: "app")
    learner.record(action: "buka Mail", category: "app")
    precondition(learner.suggestions().isEmpty, "harusnya kosong di bawah ambang 3")
}

func testHabitLearnerSuggestionsDetectsRoutine() {
    let learner = HabitLearner()
    // Senin jam 9 (dayOfWeek=2, hour=9)
    learner.now = { Date(timeIntervalSince1970: 1_700_000_000) } // Senin 14 Nov 2023 09:xx
    learner.clear()
    for _ in 0..<5 {
        learner.record(action: "buka Mail", category: "app")
    }
    let suggestions = learner.suggestions()
    precondition(suggestions.count == 1, "harusnya 1 saran, dapet \(suggestions.count)")
    precondition(suggestions[0].action == "buka Mail", "action salah: \(suggestions[0].action)")
    precondition(suggestions[0].category == "app", "category salah: \(suggestions[0].category)")
    precondition(suggestions[0].confidence >= 0.5, "confidence terlalu rendah: \(suggestions[0].confidence)")
    precondition(!suggestions[0].title.isEmpty, "title kosong")
}

func testHabitLearnerSortedByConfidence() {
    let learner = HabitLearner()
    learner.now = { Date(timeIntervalSince1970: 1_700_000_000) }
    learner.clear()
    // Rutinisasi "tulis file" 9 kali (confidence 0.9) vs "buka Mail" 4 kali (0.4 → akan dihilangkan minConfidence 0.5)
    for _ in 0..<9 { learner.record(action: "tulis file", category: "file") }
    for _ in 0..<4 { learner.record(action: "buka Mail", category: "app") }
    let suggestions = learner.suggestions(minConfidence: 0.5)
    precondition(suggestions.count == 1, "harusnya hanya 'tulis file' yang lolos 0.5, dapet \(suggestions.count)")
    precondition(suggestions[0].action == "tulis file", "yang tertinggi harusnya tulis file: \(suggestions[0].action)")
}

func testHabitLearnerMinConfidenceFilter() {
    let learner = HabitLearner()
    learner.now = { Date(timeIntervalSince1970: 1_700_000_000) }
    learner.clear()
    for _ in 0..<6 { learner.record(action: "cek email", category: "app") } // confidence 0.6
    let high = learner.suggestions(minConfidence: 0.5)
    precondition(high.count == 1, "harusnya 1 pada 0.5, dapet \(high.count)")
    let low = learner.suggestions(minConfidence: 0.7)
    precondition(low.isEmpty, "harusnya kosong pada 0.7, dapet \(low.count)")
}

func testHabitLearnerNowInjection() {
    let learner = HabitLearner()
    // Date 1700000000 = Senin 14 Nov 2023 ~09:33 UTC. Paksa now tetap.
    learner.now = { Date(timeIntervalSince1970: 1_700_000_000) }
    learner.clear()
    for _ in 0..<5 { learner.record(action: "buka Mail", category: "app") }
    let s = learner.suggestions()
    precondition(!s.isEmpty, "harusnya ada saran saat now diinject")
    // Kembalikan now ke Date() (default) — tidak boleh crash.
    learner.now = Date.init
    _ = learner.suggestions()
}

// MARK- ProactiveEngine habit integration

func testProactiveEngineIncludesHabitChips() {
    let engine = ProactiveEngine.shared
    engine.learner.clear()
    // Kosongkan memori agar hanya chip kebiasaan yang tersisa.
    // (MemoryService.shared.all() dibaca langsung; kita tidak bisa membersihkannya
    //  dengan mudah di sini, jadi cukup verifikasi bahwa chip kebiasaan ditambahkan.)
    let before = engine.chips.count
    for _ in 0..<5 {
        engine.learner.record(action: "buka Mail", category: "app")
    }
    engine.refresh()
    precondition(engine.chips.count > before, "chip kebaisan harus bertambah setelah refresh, sebelum=\(before) setelah=\(engine.chips.count)")
    precondition(engine.chips.contains { $0.fact == "buka Mail" }, "harus ada chip dengan fact 'buka Mail'")
}

func testProactiveEngineRecordHabitDelegates() {
    let engine = ProactiveEngine.shared
    engine.learner.clear()
    let before = engine.learner.count
    engine.recordHabit(action: "tulis laporan", category: "chat")
    precondition(engine.learner.count == before + 1, "recordHabit harus menambah entri learner")
}
