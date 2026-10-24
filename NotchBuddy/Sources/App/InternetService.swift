import Foundation

struct WebSearchResult: Sendable, Equatable {
    let title: String
    let url: String
    let snippet: String
}

enum InternetError: LocalizedError, Equatable {
    case invalidQuery
    case invalidURL(String)
    case badResponse(Int)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .invalidQuery: return "Empty search query."
        case .invalidURL(let value): return "Not a web URL: \(value)"
        case .badResponse(let code): return "Server returned HTTP \(code)."
        case .network(let message): return message
        }
    }
}

enum InternetService {
    static let searchTimeout: TimeInterval = 8
    static let fetchTimeout: TimeInterval = 15
    static let maxPageBytes = 1_500_000
    static let maxPageChars = 12_000

    private static let endpoint = "https://html.duckduckgo.com/html/"
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
    private static let acceptHeader =
        "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.httpMaximumConnectionsPerHost = 5
        return URLSession(configuration: config, delegate: nil, delegateQueue: nil)
    }()

    // MARK: - Public API

    static func search(_ query: String, limit: Int = 6) async throws -> [WebSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw InternetError.invalidQuery }

        // 1. Coba DuckDuckGo terlebih dahulu
        do {
            if var components = URLComponents(string: endpoint) {
                components.queryItems = [URLQueryItem(name: "q", value: trimmed)]
                if let url = components.url {
                    let html = try await get(url, timeout: searchTimeout)
                    let ddgResults = searchResults(from: html, limit: limit)
                    if !ddgResults.isEmpty {
                        return ddgResults
                    }
                }
            }
        } catch {
            // DuckDuckGo gagal (misal diblokir ISP / TLS handshake gagal di Indonesia)
            // Lanjut ke fallback Bing
        }

        // 2. Fallback otomatis ke Bing Search
        return try await searchBing(trimmed, limit: limit)
    }

    static func fetchPage(_ urlString: String) async throws -> String {
        guard let url = safeWebURL(urlString) else {
            throw InternetError.invalidURL(urlString)
        }
        let html = try await get(url, timeout: fetchTimeout)
        return readableText(from: html, maxChars: maxPageChars)
    }

    static func formatForContext(_ results: [WebSearchResult], query: String, limit: Int = 6) -> String {
        guard !results.isEmpty else { return "No web results found." }
        var lines = "Web search results for \"\(query)\":"
        for (index, result) in results.prefix(limit).enumerated() {
            lines += "\n\(index + 1). \(String(result.title.prefix(160)))"
            lines += "\n   \(result.url)"
            if !result.snippet.isEmpty {
                lines += "\n   \(String(result.snippet.prefix(240)))"
            }
        }
        return lines
    }

    // MARK: - DuckDuckGo HTML parsing

    static func searchResults(from html: String, limit: Int = 6) -> [WebSearchResult] {
        guard !html.isEmpty, limit > 0 else { return [] }

        var results: [WebSearchResult] = []
        var pendingTitle: String?
        var pendingHref: String?
        var pendingSnippet = ""

        func commit() {
            if let title = pendingTitle, let href = pendingHref,
               let url = resolveRedirect(href) {
                results.append(
                    WebSearchResult(title: title, url: url.absoluteString, snippet: pendingSnippet))
            }
            pendingTitle = nil
            pendingHref = nil
            pendingSnippet = ""
        }

        for anchor in anchorMatches(in: html) {
            if anchor.attrs.contains("result__snippet") {
                if pendingTitle != nil {
                    pendingSnippet = plainText(anchor.text)
                }
                continue
            }
            if anchor.attrs.contains("result__a") {
                commit()
                pendingTitle = plainText(anchor.text)
                pendingHref = anchor.href
            }
        }
        commit()

        return Array(results.prefix(limit))
    }

    // MARK: - Bing Search Fallback

    static func searchBing(_ query: String, limit: Int = 6) async throws -> [WebSearchResult] {
        guard var components = URLComponents(string: "https://www.bing.com/search") else {
            throw InternetError.invalidQuery
        }
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = components.url else { throw InternetError.invalidQuery }
        let html = try await get(url, timeout: searchTimeout)
        return bingSearchResults(from: html, limit: limit)
    }

    static func bingSearchResults(from html: String, limit: Int = 6) -> [WebSearchResult] {
        guard !html.isEmpty, limit > 0 else { return [] }

        guard let blockRegex = try? NSRegularExpression(
            pattern: "<li\\b[^>]*class=\"[^\"]*b_algo[^\"]*\"[^>]*>(.*?)</li>",
            options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }

        guard let linkRegex = try? NSRegularExpression(
            pattern: "<h2><a\\s+[^>]*href=\"([^\"]+)\"[^>]*>(.*?)</a></h2>",
            options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }

        guard let pRegex = try? NSRegularExpression(
            pattern: "<p[^>]*>(.*?)</p>",
            options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }

        let ns = html as NSString
        let matches = blockRegex.matches(in: html, options: [], range: NSRange(location: 0, length: ns.length))
        var results: [WebSearchResult] = []

        for match in matches {
            let block = ns.substring(with: match.range)
            let blockNs = block as NSString

            guard let linkMatch = linkRegex.firstMatch(in: block, options: [], range: NSRange(location: 0, length: blockNs.length)),
                  linkMatch.numberOfRanges >= 3 else { continue }
            let rawUrl = blockNs.substring(with: linkMatch.range(at: 1))
            let rawTitle = blockNs.substring(with: linkMatch.range(at: 2))

            var snippet = ""
            if let pMatch = pRegex.firstMatch(in: block, options: [], range: NSRange(location: 0, length: blockNs.length)),
               pMatch.numberOfRanges >= 2 {
                snippet = plainText(blockNs.substring(with: pMatch.range(at: 1)))
            }

            let title = plainText(rawTitle)
            var cleanUrl = rawUrl

            // Decode redirect jika format /ck/a?!...&u=a1<base64>
            if let uRange = rawUrl.range(of: "u=a1") {
                let afterU = String(rawUrl[uRange.upperBound...])
                let b64Clean = afterU.prefix { $0 != "&" && $0 != "\"" }
                let padded = String(b64Clean) + "=="
                if let data = Data(base64Encoded: padded) ?? Data(base64Encoded: String(b64Clean)),
                   let decoded = String(data: data, encoding: .utf8),
                   decoded.hasPrefix("http") {
                    cleanUrl = decoded
                }
            }

            if let valid = safeWebURL(cleanUrl) {
                results.append(WebSearchResult(title: title, url: valid.absoluteString, snippet: snippet))
                if results.count >= limit { break }
            }
        }

        return results
    }

    static func resolveRedirect(_ href: String) -> URL? {
        let decoded = decodeEntities(href)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !decoded.isEmpty else { return nil }

        let candidate = decoded.hasPrefix("//") ? "https:" + decoded : decoded
        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased() else { return nil }
        guard scheme == "http" || scheme == "https" else { return nil }

        // DuckDuckGo redirect: /l/?uddg=<encoded target>&rut=...
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let items = components.queryItems,
           let target = items.first(where: { $0.name == "uddg" })?.value,
           let direct = safeWebURL(target) {
            return direct
        }
        return safeWebURL(candidate)
    }

    static func decodeEntities(_ input: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: "&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z][a-zA-Z0-9]*);") else { return input }
        let ns = input as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        let matches = regex.matches(in: input, options: [], range: fullRange)
        guard !matches.isEmpty else { return input }

        var out = ""
        var last = 0
        for match in matches {
            out += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let entity = ns.substring(with: match.range)
            out += decodeEntity(entity) ?? entity
            last = match.range.location + match.range.length
        }
        out += ns.substring(with: NSRange(location: last, length: ns.length - last))
        return out
    }

    static func readableText(from html: String, maxChars: Int = maxPageChars) -> String {
        guard !html.isEmpty else { return "" }
        var text = html

        // HTML comments first so tags inside them are never treated as real.
        text = replacing(pattern: "<!--.*?-->", options: [.dotMatchesLineSeparators],
                         in: text, with: " ")
        // Whole non-content elements.
        text = replacing(
            pattern: "<(script|style|noscript|svg|nav|header|footer|form)\\b[^>]*>.*?</\\1\\s*>",
            options: [.caseInsensitive, .dotMatchesLineSeparators], in: text, with: " ")
        // Block-level boundaries become line breaks.
        text = replacing(
            pattern: "</?(p|div|br|hr|h[1-6]|li|tr|td|th|ul|ol|table|section|article|aside|blockquote|pre|main|figure)\\b[^>]*>",
            options: [.caseInsensitive], in: text, with: "\n")
        // Anything left is an inline tag — drop it.
        text = replacing(pattern: "</?[a-zA-Z][^>]*>", options: [.caseInsensitive],
                         in: text, with: "")
        text = decodeEntities(text)

        let lines = text.components(separatedBy: "\n").map { collapsingWhitespace($0) }
        var out = ""
        for line in lines where !line.isEmpty {
            if !out.isEmpty { out += "\n" }
            out += line
        }
        if out.count > maxChars {
            out = String(out.prefix(maxChars)) + "…"
        }
        return out
    }

    // MARK: - Internals

    private struct Anchor {
        let attrs: String
        let text: String
        let href: String
    }

    private static func get(_ url: URL, timeout: TimeInterval) async throws -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(acceptHeader, forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("gzip, deflate, br", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("https://duckduckgo.com/", forHTTPHeaderField: "Referer")
        request.setValue("keep-alive", forHTTPHeaderField: "Connection")
        request.setValue("upgrade-insecure-requests", forHTTPHeaderField: "Upgrade-Insecure-Requests")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain {
                switch nsError.code {
                case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasUnknownRoot:
                    throw InternetError.network("TLS/SSL connection failed to \(url.host ?? "unknown"). The server may require a newer TLS version or the certificate is not trusted.")
                case NSURLErrorNotConnectedToInternet:
                    throw InternetError.network("No internet connection.")
                case NSURLErrorCannotConnectToHost:
                    throw InternetError.network("Cannot connect to \(url.host ?? "unknown"). Check your internet connection.")
                case NSURLErrorTimedOut:
                    throw InternetError.network("Connection timed out to \(url.host ?? "unknown").")
                default:
                    throw InternetError.network("Network error: \(error.localizedDescription)")
                }
            }
            throw InternetError.network("Network error: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw InternetError.network("No HTTP response.")
        }
        guard http.statusCode == 200 else {
            throw InternetError.badResponse(http.statusCode)
        }
        return String(decoding: data.prefix(maxPageBytes), as: UTF8.self)
    }

    private static func anchorMatches(in html: String) -> [Anchor] {
        guard let regex = try? NSRegularExpression(
            pattern: "<a\\b([^>]*)>(.*?)</a>",
            options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        var anchors: [Anchor] = []
        regex.enumerateMatches(in: html, options: [], range: range) { match, _, _ in
            guard let match else { return }
            let attrs = (html as NSString).substring(with: match.range(at: 1))
            let text = (html as NSString).substring(with: match.range(at: 2))
            guard let href = firstAttribute("href", in: attrs) else { return }
            anchors.append(Anchor(attrs: attrs, text: text, href: href))
        }
        return anchors
    }

    private static func firstAttribute(_ name: String, in attrs: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: "\\b\(name)\\s*=\\s*\"([^\"]*)\"",
            options: [.caseInsensitive]) else { return nil }
        let range = NSRange(attrs.startIndex..<attrs.endIndex, in: attrs)
        guard let match = regex.firstMatch(in: attrs, options: [], range: range),
              match.numberOfRanges > 1 else { return nil }
        return (attrs as NSString).substring(with: match.range(at: 1))
    }

    private static func plainText(_ raw: String) -> String {
        let stripped = replacing(pattern: "</?[a-zA-Z][^>]*>", options: [.caseInsensitive],
                                 in: raw, with: " ")
        return collapsingWhitespace(decodeEntities(stripped))
    }

    private static func collapsingWhitespace(_ text: String) -> String {
        let collapsed = replacing(pattern: "\\s+", options: [], in: text, with: " ")
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replacing(pattern: String, options: NSRegularExpression.Options,
                                  in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range,
                                              withTemplate: template)
    }

    private static func decodeEntity(_ entity: String) -> String? {
        let inner = String(entity.dropFirst().dropLast())
        if inner.hasPrefix("#x") || inner.hasPrefix("#X") {
            guard let value = UInt32(inner.dropFirst(2), radix: 16),
                  let scalar = UnicodeScalar(value) else { return nil }
            return String(Character(scalar))
        }
        if inner.hasPrefix("#") {
            guard let value = UInt32(inner.dropFirst()),
                  let scalar = UnicodeScalar(value) else { return nil }
            return String(Character(scalar))
        }
        let named: [String: String] = [
            "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
            "nbsp": " ", "mdash": "\u{2014}", "ndash": "\u{2013}", "hellip": "\u{2026}",
        ]
        return named[inner.lowercased()]
    }
}
