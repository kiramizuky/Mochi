import Foundation

print("=== MEMULAI TEST SUITE TELEGRAM MARKDOWNV2 & SYSTEM METRICS ===")

// 1. Uji escaping MarkdownV2
let rawText = "RAM: 11.0 / 16.0 GB (69%)! Versi: 1.0.0. Status: OK."
let specialChars: Set<Character> = ["_", "[", "]", "(", ")", "~", ">", "#", "+", "-", "=", "|", "{", "}", ".", "!"]

var escaped = ""
for char in rawText {
    if specialChars.contains(char) {
        escaped.append("\\")
        escaped.append(char)
    } else {
        escaped.append(char)
    }
}

print("Raw: \(rawText)")
print("Escaped: \(escaped)")
assert(escaped.contains("\\."), "Titik harus di-escape")
assert(escaped.contains("\\!"), "Tanda seru harus di-escape")
assert(escaped.contains("\\("), "Kurung buka harus di-escape")
assert(escaped.contains("\\)"), "Kurung tutup harus di-escape")

// 2. Uji visual bar
func makeBar(percent: Double, length: Int = 8) -> String {
    let filled = max(0, min(length, Int((percent / 100.0) * Double(length))))
    let empty = length - filled
    return String(repeating: "■", count: filled) + String(repeating: "□", count: empty)
}

let bar50 = makeBar(percent: 50)
print("Bar 50%: \(bar50)")
assert(bar50 == "■■■■□□□□", "Progress bar 50% harus 4 penuh dan 4 kosong")

let bar75 = makeBar(percent: 75)
print("Bar 75%: \(bar75)")
assert(bar75 == "■■■■■■□□", "Progress bar 75% harus 6 penuh dan 2 kosong")

print("=== SEMUA TEST TELEGRAM MARKDOWNV2 LULUS (100%) ===")
