import Foundation

// MARK: - Canvas Artifact Data Model

public enum ArtifactType: String, Codable, Sendable, CaseIterable {
    case document = "document"   // Markdown, laporan, SOP terstruktur
    case table    = "table"      // Spreadsheet TSV/CSV/Grid data
    case code     = "code"       // Snippet kode / script automasi
    case chart    = "chart"      // Diagram alur, Mermaid, ASCII chart
    case html     = "html"       // Live Web Sandbox / Visualisasi HTML5
    case form     = "form"       // Form input & widget interaktif
    case media    = "media"      // Pemutar Audio / Video Layar Lebar
    case gallery  = "gallery"    // Galeri Foto / Screenshot Multi-Kolom

    public var iconName: String {
        switch self {
        case .document: return "doc.text.fill"
        case .table:    return "tablecells.fill"
        case .code:     return "curlybraces"
        case .chart:    return "chart.bar.xaxis"
        case .html:     return "globe.americas.fill"
        case .form:     return "slider.horizontal.3"
        case .media:    return "play.rectangle.fill"
        case .gallery:  return "photo.on.rectangle.angled"
        }
    }

    public var displayName: String {
        switch self {
        case .document: return "Dokumen"
        case .table:    return "Tabel Data"
        case .code:     return "Kode"
        case .chart:    return "Diagram"
        case .html:     return "Web Sandbox"
        case .form:     return "Form Interaktif"
        case .media:    return "Media Studio"
        case .gallery:  return "Galeri Media"
        }
    }
}

public struct CanvasArtifact: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var type: ArtifactType
    public var content: String
    public var metadata: [String: String]
    public var createdAt: Date

    public init(id: String = UUID().uuidString,
                title: String,
                type: ArtifactType = .document,
                content: String,
                metadata: [String: String] = [:],
                createdAt: Date = Date()) {
        self.id = id
        self.title = title
        self.type = type
        self.content = content
        self.metadata = metadata
        self.createdAt = createdAt
    }
}
