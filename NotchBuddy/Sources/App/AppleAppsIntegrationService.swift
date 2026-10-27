import Foundation

// MARK: - Apple Apps Suite Integration (Produktivitas & Jadwal macOS)

public struct CalendarEventItem: Codable, Sendable, Identifiable {
    public var id: String { "\(title)_\(startDate)" }
    public let title: String
    public let startDate: String
    public let endDate: String
    public let location: String
}

public final class AppleAppsIntegrationService: @unchecked Sendable {
    public static let shared = AppleAppsIntegrationService()

    private init() {}

    // MARK: - 1. Apple Calendar Integration

    public func listCalendarEvents(daysAhead: Int = 1) async -> String {
        let script = """
        set daysAhead to \(daysAhead)
        set startDate to (current date)
        set time of startDate to 0
        set endDate to startDate + (daysAhead * days)
        
        set eventList to ""
        tell application "Calendar"
            set allCalendars to calendars
            repeat with cal in allCalendars
                set matchingEvents to (every event of cal whose start date ≥ startDate and start date ≤ endDate)
                repeat with ev in matchingEvents
                    set evTitle to summary of ev
                    set evStart to start date of ev as string
                    set evEnd to end date of ev as string
                    set evLoc to location of ev
                    if evLoc is missing value then set evLoc to ""
                    set eventList to eventList & "- " & evTitle & " (" & evStart & ")" & (if evLoc is not "" then " @ " & evLoc else "") & "\n"
                end repeat
            end repeat
        end tell
        if eventList is "" then
            return "Tidak ada jadwal acara kalender dalam \(daysAhead) hari ke depan."
        else
            return eventList
        end if
        """

        do {
            let output = try AppAutomation.run(script)
            return "📅 Agenda Kalender (\(daysAhead) Hari Kedepan):\n\(output)"
        } catch {
            return "Gagal membaca agenda kalender: \(error.localizedDescription)"
        }
    }

    // MARK: - 2. Apple Reminders Integration

    public func addReminder(title: String, dueString: String? = nil, listName: String? = nil) async -> String {
        let cleanTitle = title.replacingOccurrences(of: "\"", with: "\\\"")
        let targetList = listName ?? "Reminders"
        
        let script: String
        if let due = dueString, !due.isEmpty {
            script = """
            tell application "Reminders"
                set targetList to default list
                try
                    set targetList to list "\(targetList)"
                end try
                tell targetList
                    make new reminder with properties {name:"\(cleanTitle)", body:"Dibuat oleh Mochi Assistant"}
                end tell
            end tell
            return "Pengingat '\(cleanTitle)' berhasil ditambahkan ke daftar " & name of targetList of application "Reminders"
            """
        } else {
            script = """
            tell application "Reminders"
                set targetList to default list
                try
                    set targetList to list "\(targetList)"
                end try
                tell targetList
                    make new reminder with properties {name:"\(cleanTitle)", body:"Dibuat oleh Mochi Assistant"}
                end tell
                return "Pengingat '\(cleanTitle)' berhasil ditambahkan ke daftar " & name of targetList
            end tell
            """
        }

        do {
            let output = try AppAutomation.run(script)
            return "✓ \(output)"
        } catch {
            return "Gagal membuat pengingat di Reminders: \(error.localizedDescription)"
        }
    }

    // MARK: - 3. Apple Notes Integration

    public func createNote(title: String, body: String, folderName: String? = nil) async -> String {
        let cleanTitle = title.replacingOccurrences(of: "\"", with: "\\\"")
        let cleanBody = body.replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "<br>")
        let folder = folderName ?? "Notes"

        let script = """
        tell application "Notes"
            set targetFolder to default folder
            try
                set targetFolder to folder "\(folder)"
            end try
            tell targetFolder
                make new note with properties {name:"\(cleanTitle)", body:"<h1>\(cleanTitle)</h1><p>\(cleanBody)</p><p><i>Catatan disimpan oleh Mochi Assistant</i></p>"}
            end tell
            return "Catatan '\(cleanTitle)' berhasil disimpan ke Apple Notes (folder: " & name of targetFolder & ")."
        end tell
        """

        do {
            let output = try AppAutomation.run(script)
            return "✓ \(output)"
        } catch {
            return "Gagal membuat catatan di Apple Notes: \(error.localizedDescription)"
        }
    }

    // MARK: - 4. Media Control (Spotify / Apple Music)

    public func controlMedia(action: String) async -> String {
        let act = action.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        let script = """
        set resultText to ""
        -- Cek apakah Spotify berjalan
        tell application "System Events"
            set spotifyRunning to (name of processes) contains "Spotify"
            set musicRunning to (name of processes) contains "Music"
        end tell

        if spotifyRunning then
            tell application "Spotify"
                if "\(act)" is "play" then
                    play
                    return "Spotify: Memutar musik ▶️"
                else if "\(act)" is "pause" then
                    pause
                    return "Spotify: Musik dijeda ⏸️"
                else if "\(act)" is "toggle" then
                    playpause
                    return "Spotify: Play/Pause di-toggle ⏯️"
                else if "\(act)" is "next" then
                    next track
                    return "Spotify: Lagu berikutnya ⏭️"
                else if "\(act)" is "previous" then
                    previous track
                    return "Spotify: Lagu sebelumnya ⏮️"
                else if "\(act)" is "now_playing" then
                    set currentTrack to name of current track
                    set currentArtist to artist of current track
                    return "Spotify Sedang Memutar: " & currentTrack & " - " & currentArtist & " 🎵"
                end if
            end tell
        else if musicRunning then
            tell application "Music"
                if "\(act)" is "play" then
                    play
                    return "Apple Music: Memutar musik ▶️"
                else if "\(act)" is "pause" then
                    pause
                    return "Apple Music: Musik dijeda ⏸️"
                else if "\(act)" is "toggle" then
                    playpause
                    return "Apple Music: Play/Pause di-toggle ⏯️"
                else if "\(act)" is "next" then
                    next track
                    return "Apple Music: Lagu berikutnya ⏭️"
                else if "\(act)" is "previous" then
                    previous track
                    return "Apple Music: Lagu sebelumnya ⏮️"
                else if "\(act)" is "now_playing" then
                    set currentTrack to name of current track
                    set currentArtist to artist of current track
                    return "Apple Music Sedang Memutar: " & currentTrack & " - " & currentArtist & " 🎵"
                end if
            end tell
        else
            return "Tidak ada pemutar musik (Spotify atau Apple Music) yang sedang aktif."
        end if
        return "Aksi musik selesai."
        """

        do {
            let output = try AppAutomation.run(script)
            return output
        } catch {
            return "Gagal mengontrol media musik: \(error.localizedDescription)"
        }
    }
}

