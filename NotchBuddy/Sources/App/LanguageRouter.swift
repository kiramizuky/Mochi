import Foundation

// MARK: - Language router — deteksi bahasa input agar jawabnya pakai bahasa yang sama

/// Deteksi bahasa dari teks pengguna dengan heuristik stopword.
/// Mengembalikan kode ISO-639-1 ("id", "en", "fr", "es", "de") atau `""`
/// jika bahasa tidak dapat dideteksi dengan cukup yakin.
enum LanguageRouter {
    static func detect(_ text: String) -> String {
        let t = text.lowercased()
        let tokens = Set(t.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation }).map(String.init))
        guard !tokens.isEmpty else { return "" }

        let stopwords: [String: [String]] = [
            "id": ["yang", "dan", "di", "ke", "dari", "untuk", "dengan", "ini", "itu", "apa",
                   "siapa", "kapan", "bagaimana", "mengapa", "saya", "kamu", "dia", "adalah",
                   "tidak", "ada", "juga", "sudah", "belum", "akan", "boleh", "harus"],
            "en": ["the", "and", "to", "of", "a", "in", "for", "is", "on", "that", "with", "you",
                   "i", "it", "this", "are", "was", "be", "as", "at", "by", "or", "from", "not",
                   "have", "has", "had"],
            "fr": ["le", "la", "de", "et", "un", "une", "des", "que", "qui", "est", "pour", "dans",
                   "avec", "je", "tu", "il", "elle", "ne", "pas", "du", "au", "aux", "ce", "cet"],
            "es": ["el", "la", "de", "que", "y", "en", "un", "es", "se", "no", "por", "con",
                   "para", "una", "los", "las", "del", "al", "como", "más", "su", "lo"],
            "de": ["der", "die", "das", "und", "in", "den", "zu", "ist", "mit", "nicht", "ein",
                   "eine", "ich", "du", "sie", "es", "wir", "ihr", "auf", "für", "aus", "von"],
        ]

        var best = ("", 0)
        for (lang, words) in stopwords {
            var n = 0
            for w in words where tokens.contains(w) { n += 1 }
            if n > best.1 { best = (lang, n) }
        }

        let ratio = Double(best.1) / Double(tokens.count)
        if best.1 >= 2 && ratio >= 0.10 { return best.0 }
        return ""
    }

    /// Instruksi tambahan yang disuntik ke system prompt per-turn (hanya jika bahasa diketahui).
    static func systemInstruction(for language: String) -> String {
        guard !language.isEmpty else { return "" }
        switch language {
        case "id": return "Respond in Indonesian (Bahasa Indonesia). Keep the persona and style unchanged."
        case "en": return "Respond in English."
        case "fr": return "Répondez en français (Français)."
        case "es": return "Responde en español."
        case "de": return "Antworten Sie auf Deutsch."
        default: return ""
        }
    }
}
