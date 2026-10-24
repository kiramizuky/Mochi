import SwiftUI
import AppKit

// MARK: - Canvas View (Artifacts Studio UI)

public struct CanvasView: View {
    @ObservedObject var manager = CanvasManager.shared
    @State private var viewMode: ViewMode = .formatted
    @State private var searchText: String = ""
    @State private var copiedToast: Bool = false

    enum ViewMode: String, CaseIterable {
        case formatted = "Preview"
        case raw       = "Raw Teks"
    }

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            // Header Bar
            headerBar
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
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
        .frame(minWidth: 580, minHeight: 460)
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
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    Text("\(artifact.type.displayName) • \(formattedDate(artifact.createdAt))")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            } else {
                Text("Canvas Studio")
                    .font(.system(size: 14, weight: .semibold))
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
                .frame(width: 150)
            }

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

    // MARK: - Table Grid View

    private func tableGridView(content: String) -> some View {
        let rows = parseTableRows(content)
        return ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                    HStack(spacing: 1) {
                        // Nomor Baris
                        Text(rowIndex == 0 ? "#" : "\(rowIndex)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                            .frame(width: 32, alignment: .center)
                            .padding(.vertical, 6)
                            .background(Color(nsColor: .controlBackgroundColor).opacity(0.8))

                        // Kolom Sel
                        ForEach(Array(row.enumerated()), id: \.offset) { colIndex, cell in
                            Text(cell)
                                .font(.system(size: 12, weight: rowIndex == 0 ? .semibold : .regular))
                                .foregroundColor(rowIndex == 0 ? .primary : .secondary)
                                .frame(minWidth: 100, alignment: .leading)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .background(
                                    rowIndex == 0
                                        ? Color.accentColor.opacity(0.12)
                                        : (rowIndex % 2 == 0 ? Color(nsColor: .controlBackgroundColor).opacity(0.4) : Color.clear)
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
            Text("Minta asisten membuat rekap Excel, dokumen SOP, atau kode untuk melihat preview di sini.")
                .font(.system(size: 12))
                .foregroundColor(.secondary.opacity(0.8))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
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
                .frame(width: 100)
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
}
