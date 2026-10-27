import SwiftUI
import AppKit
import WebKit

// MARK: - Canvas View (Artifacts Studio UI & Interactive HUD)

public struct CanvasView: View {
    @ObservedObject var manager = CanvasManager.shared
    @State private var viewMode: ViewMode = .formatted
    @State private var searchText: String = ""
    @State private var copiedToast: Bool = false
    @State private var sortColumn: Int? = nil
    @State private var sortAsc: Bool = true

    // State untuk Form Interaktif
    @State private var formValues: [String: String] = [:]
    @State private var formSubmitted: Bool = false
    @State private var formOutput: String? = nil

    enum ViewMode: String, CaseIterable {
        case formatted = "Preview"
        case raw       = "Raw Teks"
    }

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            // Header Bar dengan HUD & Pinning Controls
            headerBar
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial)

            Divider()
                .opacity(0.3)

            // Content Area
            if let artifact = manager.currentArtifact {
                ZStack {
                    Color(nsColor: .windowBackgroundColor).opacity(0.5)

                    VStack(spacing: 0) {
                        switch artifact.type {
                        case .table:
                            if viewMode == .formatted {
                                tableGridView(content: artifact.content)
                            } else {
                                rawTextView(content: artifact.content)
                            }
                        case .code:
                            codeSnippetView(content: artifact.content)
                        case .document, .chart:
                            if viewMode == .formatted {
                                documentMarkdownView(content: artifact.content)
                            } else {
                                rawTextView(content: artifact.content)
                            }
                        case .html:
                            if viewMode == .formatted {
                                htmlSandboxView(content: artifact.content)
                            } else {
                                rawTextView(content: artifact.content)
                            }
                        case .form:
                            if viewMode == .formatted {
                                interactiveFormView(content: artifact.content)
                            } else {
                                rawTextView(content: artifact.content)
                            }
                        }
                    }
                }
            } else {
                emptyStateView
            }

            Divider()
                .opacity(0.3)

            // Footer Bar
            footerBar
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial)
        }
        .frame(minWidth: 620, minHeight: 480)
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        HStack(spacing: 12) {
            if let artifact = manager.currentArtifact {
                Image(systemName: artifact.type.iconName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.accentColor)
                    .frame(width: 28, height: 28)
                    .background(Color.accentColor.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 2) {
                    Text(artifact.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text("\(artifact.type.displayName) • \(formattedDate(artifact.createdAt))")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            } else {
                Text("Canvas Studio")
                    .font(.system(size: 13, weight: .semibold))
            }

            Spacer()

            // View Mode Picker (Formatted vs Raw)
            if manager.currentArtifact?.type != .code {
                Picker("", selection: $viewMode) {
                    ForEach(ViewMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 140)
            }

            // HUD Controls (Corner Docking, Opacity, Pin-to-Desktop)
            HStack(spacing: 4) {
                // Dock Corner Menu
                Menu {
                    Button(action: { manager.setDockCorner(.belowNotch) }) {
                        Label("Bawah Notch", systemImage: manager.currentCorner == .belowNotch ? "checkmark" : "")
                    }
                    Button(action: { manager.setDockCorner(.topRight) }) {
                        Label("Kanan Atas", systemImage: manager.currentCorner == .topRight ? "checkmark" : "")
                    }
                    Button(action: { manager.setDockCorner(.bottomRight) }) {
                        Label("Kanan Bawah", systemImage: manager.currentCorner == .bottomRight ? "checkmark" : "")
                    }
                    Button(action: { manager.setDockCorner(.center) }) {
                        Label("Tengah Layar", systemImage: manager.currentCorner == .center ? "checkmark" : "")
                    }
                } label: {
                    Image(systemName: "pip.swap")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 20, height: 20)
                }
                .menuStyle(.borderlessButton)
                .help("Pindahkan Posisi Docking Canvas")

                // Transparansi Kaca Menu
                Menu {
                    Button("Solid (100%)") { manager.setOpacity(1.0) }
                    Button("Kaca Lembut (85%)") { manager.setOpacity(0.85) }
                    Button("Kaca Transparan (70%)") { manager.setOpacity(0.70) }
                } label: {
                    Image(systemName: "circle.lefthalf.filled")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 20, height: 20)
                }
                .menuStyle(.borderlessButton)
                .help("Atur Tingkat Transparansi Jendela")

                // Tombol Pin (Floating HUD)
                Button {
                    manager.togglePin()
                } label: {
                    Image(systemName: manager.isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(manager.isPinned ? .accentColor : .secondary)
                        .padding(5)
                }
                .buttonStyle(.plain)
                .help(manager.isPinned ? "Lepaskan Pin (Mode Normal)" : "Sematkan di Atas (Floating HUD)")
            }
            .padding(.horizontal, 4)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
            .cornerRadius(6)

            // Action Buttons
            HStack(spacing: 6) {
                // Tombol Salin
                Button {
                    manager.copyToClipboard()
                    withAnimation { copiedToast = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        withAnimation { copiedToast = false }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: copiedToast ? "checkmark" : "doc.on.doc")
                        Text(copiedToast ? "Tersalin" : "Salin")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.bordered)

                // Ekspor ke Word (jika dokumen / kode)
                if manager.currentArtifact?.type == .document || manager.currentArtifact?.type == .code {
                    Button {
                        manager.exportToWord()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.richtext")
                            Text("Buka di Word")
                        }
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                }

                // Ekspor ke Excel (jika tabel)
                if manager.currentArtifact?.type == .table {
                    Button {
                        manager.exportToExcel()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "tablecells.badge.ellipsis")
                            Text("Buka di Excel")
                        }
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                }

                // Tombol Tutup
                Button {
                    manager.dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.secondary)
                        .padding(6)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Table Grid View (dengan Live Search & Sorting Header)

    private func tableGridView(content: String) -> some View {
        let allRows = parseTableRows(content)
        let headerRow = allRows.first ?? []
        let rawDataRows = Array(allRows.dropFirst())

        // 1. Filter baris data berdasarkan teks pencarian
        var filteredRows = rawDataRows
        if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            let q = searchText.lowercased()
            filteredRows = filteredRows.filter { row in
                row.contains { $0.lowercased().contains(q) }
            }
        }

        // 2. Sort kolom jika pengguna mengklik salah satu header
        if let sortCol = sortColumn, sortCol < headerRow.count {
            filteredRows.sort { r1, r2 in
                let val1 = sortCol < r1.count ? r1[sortCol].trimmingCharacters(in: .whitespaces) : ""
                let val2 = sortCol < r2.count ? r2[sortCol].trimmingCharacters(in: .whitespaces) : ""
                if let n1 = Double(val1), let n2 = Double(val2) {
                    return sortAsc ? (n1 < n2) : (n1 > n2)
                }
                return sortAsc ? (val1.localizedCaseInsensitiveCompare(val2) == .orderedAscending)
                               : (val1.localizedCaseInsensitiveCompare(val2) == .orderedDescending)
            }
        }

        return VStack(spacing: 0) {
            // Search Bar untuk Tabel
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                TextField("Cari di tabel (filter seketika)...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                Text("\(filteredRows.count) dari \(rawDataRows.count) baris")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))

            Divider().opacity(0.3)

            // Grid View
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 1) {
                    // Header Baris (Dapat diklik untuk Sorting)
                    HStack(spacing: 1) {
                        Text("#")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                            .frame(width: 32, alignment: .center)
                            .padding(.vertical, 6)
                            .background(Color(nsColor: .controlBackgroundColor).opacity(0.8))

                        ForEach(Array(headerRow.enumerated()), id: \.offset) { colIndex, cell in
                            Button {
                                if sortColumn == colIndex {
                                    sortAsc.toggle()
                                } else {
                                    sortColumn = colIndex
                                    sortAsc = true
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Text(cell)
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundColor(.primary)
                                        .lineLimit(1)

                                    if sortColumn == colIndex {
                                        Image(systemName: sortAsc ? "chevron.up" : "chevron.down")
                                            .font(.system(size: 9, weight: .heavy))
                                            .foregroundColor(.accentColor)
                                    }
                                }
                                .frame(minWidth: 100, alignment: .leading)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .background(Color.accentColor.opacity(0.12))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .background(Color(nsColor: .separatorColor).opacity(0.2))

                    // Baris Data yang terfilter & tersortir
                    ForEach(Array(filteredRows.enumerated()), id: \.offset) { rowIndex, row in
                        HStack(spacing: 1) {
                            Text("\(rowIndex + 1)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                                .frame(width: 32, alignment: .center)
                                .padding(.vertical, 6)
                                .background(Color(nsColor: .controlBackgroundColor).opacity(0.8))

                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                Text(cell)
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                    .frame(minWidth: 100, alignment: .leading)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 6)
                                    .background(
                                        rowIndex % 2 == 0 ? Color(nsColor: .controlBackgroundColor).opacity(0.3) : Color.clear
                                    )
                                    .lineLimit(2)
                            }
                        }
                        .background(Color(nsColor: .separatorColor).opacity(0.2))
                    }
                }
                .padding(12)
            }
        }
    }

    // MARK: - HTML Sandbox View (WebKit Native)

    private func htmlSandboxView(content: String) -> some View {
        CanvasHTMLWebView(htmlContent: content)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Interactive Form View

    private func interactiveFormView(content: String) -> some View {
        let formSpec = parseFormSpecification(content)

        return ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 16) {
                // Header Info Form
                VStack(alignment: .leading, spacing: 4) {
                    Text(formSpec.title)
                        .font(.system(size: 16, weight: .bold))
                    if let desc = formSpec.description, !desc.isEmpty {
                        Text(desc)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                }

                Divider().opacity(0.4)

                // Render Input Fields Dinamis
                VStack(spacing: 12) {
                    ForEach(formSpec.fields, id: \.id) { field in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(field.label)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.primary)

                            if field.type == "select", let options = field.options, !options.isEmpty {
                                Picker("", selection: Binding(
                                    get: { formValues[field.id] ?? field.defaultValue ?? options.first ?? "" },
                                    set: { formValues[field.id] = $0 }
                                )) {
                                    ForEach(options, id: \.self) { opt in
                                        Text(opt).tag(opt)
                                    }
                                }
                                .pickerStyle(.menu)
                            } else if field.type == "toggle" {
                                Toggle(isOn: Binding(
                                    get: { (formValues[field.id] ?? field.defaultValue) == "true" },
                                    set: { formValues[field.id] = $0 ? "true" : "false" }
                                )) {
                                    Text(field.placeholder ?? "Aktifkan opsi ini")
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                }
                                .toggleStyle(.switch)
                            } else {
                                TextField(field.placeholder ?? "Masukkan \(field.label)...", text: Binding(
                                    get: { formValues[field.id] ?? field.defaultValue ?? "" },
                                    set: { formValues[field.id] = $0 }
                                ))
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12))
                            }
                        }
                    }
                }

                // Tombol Submit Aksi
                Button {
                    submitForm(spec: formSpec)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "paperplane.fill")
                        Text(formSpec.submitLabel ?? "Terapkan & Kirim")
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)

                // Output Feedback jika Form Dikirim
                if let output = formOutput {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("Hasil Eksekusi Formulir:")
                                .font(.system(size: 11, weight: .bold))
                        }
                        Text(output)
                            .font(.system(size: 11, design: .monospaced))
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(nsColor: .controlBackgroundColor).opacity(0.8))
                            .cornerRadius(6)
                    }
                    .padding(.top, 8)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func submitForm(spec: FormSpecification) {
        var summary: [String: String] = [:]
        for field in spec.fields {
            let val = formValues[field.id] ?? field.defaultValue ?? ""
            summary[field.label] = val
        }
        let pretty = summary.map { "• \($0.key): \($0.value)" }.joined(separator: "\n")
        formOutput = "Formulir '\(spec.title)' berhasil diproses:\n\(pretty)"
        formSubmitted = true
        // Salin ringkasan ke clipboard
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pretty, forType: .string)
    }

    // MARK: - Document Markdown View

    private func documentMarkdownView(content: String) -> some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 12) {
                let lines = content.components(separatedBy: "\n")
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("### ") {
                        Text(trimmed.replacingOccurrences(of: "### ", with: ""))
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.primary)
                            .padding(.top, 4)
                    } else if trimmed.hasPrefix("## ") {
                        Text(trimmed.replacingOccurrences(of: "## ", with: ""))
                            .font(.system(size: 17, weight: .bold))
                            .foregroundColor(.primary)
                            .padding(.top, 8)
                    } else if trimmed.hasPrefix("# ") {
                        Text(trimmed.replacingOccurrences(of: "# ", with: ""))
                            .font(.system(size: 20, weight: .heavy))
                            .foregroundColor(.primary)
                            .padding(.top, 10)
                    } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("• ") {
                        HStack(alignment: .top, spacing: 6) {
                            Text("•")
                                .foregroundColor(.accentColor)
                                .font(.system(size: 13, weight: .bold))
                            Text(trimmed.dropFirst(2))
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                        }
                    } else if trimmed.hasPrefix("=") || trimmed.hasPrefix("---") {
                        Divider().opacity(0.4)
                    } else if !trimmed.isEmpty {
                        Text(trimmed)
                            .font(.system(size: 13))
                            .foregroundColor(.primary.opacity(0.9))
                            .lineSpacing(4)
                    } else {
                        Spacer().frame(height: 6)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Code Snippet View

    private func codeSnippetView(content: String) -> some View {
        let lines = content.components(separatedBy: "\n")
        return ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(lines.enumerated()), id: \.offset) { idx, line in
                    HStack(alignment: .top, spacing: 12) {
                        Text("\(idx + 1)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary.opacity(0.6))
                            .frame(width: 30, alignment: .trailing)

                        Text(line)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.primary)
                    }
                }
            }
            .padding(16)
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
    }

    // MARK: - Raw Text View

    private func rawTextView(content: String) -> some View {
        ScrollView(.vertical) {
            Text(content)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.secondary)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.dashed")
                .font(.system(size: 40))
                .foregroundColor(.secondary.opacity(0.5))
            Text("Belum ada Artifact yang aktif")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.secondary)
            Text("Minta asisten membuat rekap Excel, formulir interaktif, halaman web sandbox, atau dokumen SOP untuk melihat preview di sini.")
                .font(.system(size: 12))
                .foregroundColor(.secondary.opacity(0.8))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Footer Bar

    private var footerBar: some View {
        HStack {
            if let content = manager.currentArtifact?.content {
                let linesCount = content.components(separatedBy: "\n").count
                let wordsCount = content.split(separator: " ").count
                Text("\(linesCount) baris • \(wordsCount) kata")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            } else {
                Text("Canvas Ready")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Spacer()

            if !manager.history.isEmpty {
                Menu {
                    ForEach(manager.history) { item in
                        Button(item.title) {
                            manager.present(artifact: item)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "clock.arrow.circlepath")
                        Text("Riwayat (\(manager.history.count))")
                    }
                    .font(.system(size: 11))
                }
                .menuStyle(.borderlessButton)
                .frame(width: 110)
            }
        }
    }

    // MARK: - Helpers

    private func parseTableRows(_ text: String) -> [[String]] {
        let lines = text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        var result: [[String]] = []

        for line in lines {
            // Deteksi pemisah tab, pipe (|), atau koma
            let cols: [String]
            if line.contains("\t") {
                cols = line.components(separatedBy: "\t")
            } else if line.contains("|") {
                cols = line.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            } else {
                cols = line.components(separatedBy: ",")
            }
            if !cols.isEmpty {
                result.append(cols)
            }
        }
        return result
    }

    private func formattedDate(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        return fmt.string(from: date)
    }

    private func parseFormSpecification(_ content: String) -> FormSpecification {
        // Coba decode JSON
        if let data = content.data(using: .utf8),
           let spec = try? JSONDecoder().decode(FormSpecification.self, from: data) {
            return spec
        }

        // Fallback: Parsing teks per baris (misal: "Port: 8080" atau "Nama: Budi")
        let lines = content.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        var fields: [FormField] = []
        for (idx, line) in lines.enumerated() {
            let parts = line.components(separatedBy: ":")
            if parts.count >= 2 {
                let lbl = parts[0].trimmingCharacters(in: .whitespaces)
                let val = parts.dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)
                fields.append(FormField(id: "field_\(idx)", label: lbl, type: "text", placeholder: lbl, defaultValue: val, options: nil))
            } else {
                let lbl = line.trimmingCharacters(in: .whitespaces)
                fields.append(FormField(id: "field_\(idx)", label: lbl, type: "text", placeholder: lbl, defaultValue: nil, options: nil))
            }
        }
        return FormSpecification(title: "Formulir Interaktif", description: "Isi data formulir berikut untuk melanjutkan aksi.", fields: fields, submitLabel: "Jalankan Aksi")
    }
}

// MARK: - Native WebKit Representable for HTML Sandbox

struct CanvasHTMLWebView: NSViewRepresentable {
    let htmlContent: String

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground") // Transparan mengikuti background Canvas
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        nsView.loadHTMLString(htmlContent, baseURL: nil)
    }
}

// MARK: - Dynamic Form Models

struct FormSpecification: Codable {
    var title: String
    var description: String?
    var fields: [FormField]
    var submitLabel: String?
}

struct FormField: Codable {
    var id: String
    var label: String
    var type: String // "text", "number", "select", "toggle"
    var placeholder: String?
    var defaultValue: String?
    var options: [String]?
}
