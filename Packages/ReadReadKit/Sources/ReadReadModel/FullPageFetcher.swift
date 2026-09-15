import Foundation
import ReadReadSupport

/// Fetches an item's own page and extracts the article from it.
///
/// Exists because feeds routinely publish a truncated summary. The user turns this on per feed
/// (``CachedSource/loadsFullPageContent``), and from then on opening an item from that feed reads
/// the article rather than the first paragraph of it.
///
/// One request, for the HTML, and nothing in it is ever executed — see ``ArticleExtractor`` for
/// why that rules out the more capable headless-browser approach.
public struct FullPageFetcher: Sendable {

    public enum Outcome: Sendable, Equatable {
        /// The article body, sanitised and ready to render.
        case extracted(html: String, textLength: Int)

        /// The page was fetched and holds no article worth showing — client-rendered, paywalled or
        /// simply not an article. A final answer, not a failure to retry.
        case unusable
    }

    public enum Failure: Error, Sendable, Equatable {
        case notAWebPage(contentType: String)
        case tooLarge(bytes: Int)
        case undecodableText
    }

    /// Refuses to hold more than this in memory for one article. Real pages are well under a
    /// megabyte of HTML; anything past this is a download that landed at an article URL.
    static let maximumBytes = 8 * 1024 * 1024

    private let client: HTTPClient
    private let timeout: TimeInterval

    public init(transport: any HTTPTransport = URLSession.shared, timeout: TimeInterval = 20) {
        // One attempt beyond the first, and impatient about it: this runs while the reading pane
        // shows a spinner, so a slow retry is worse than an honest failure.
        client = HTTPClient(transport: transport, policy: .impatient)
        self.timeout = timeout
    }

    public func fetch(_ url: URL) async throws -> Outcome {
        let reply = try await client.reply(for: request(for: url))

        let contentType = reply.header("Content-Type") ?? ""
        guard Self.isMarkup(contentType) else {
            throw Failure.notAWebPage(contentType: contentType)
        }
        guard reply.data.count <= Self.maximumBytes else {
            throw Failure.tooLarge(bytes: reply.data.count)
        }
        guard let html = Self.decode(reply.data, contentType: contentType) else {
            throw Failure.undecodableText
        }

        guard let article = ArticleExtractor.extract(from: html, baseURL: url) else {
            return .unusable
        }
        return .extracted(html: article.html, textLength: article.textLength)
    }

    // MARK: - Request

    private func request(for url: URL) -> URLRequest {
        Self.pageRequest(for: url, timeout: timeout)
    }

    /// How this app asks a website for one of its pages.
    ///
    /// Static, and shared with ``CommentsFetcher``: both features fetch an item's own page from a
    /// site the app has no relationship with, and the identification and cookie decisions below
    /// are policy about *that*, not about extraction. A second copy would be free to drift, and
    /// the drift nobody would notice is the one that starts accumulating cookies.
    static func pageRequest(for url: URL, timeout: TimeInterval, accept: String = markupAccept) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        // Honest about what it is. Impersonating a browser would get past more blocks, but this
        // reader should be identifiable to the servers it fetches from.
        request.setValue("ReadRead/1.0 (feed reader; +https://github.com/kittmedia/readread)",
                         forHTTPHeaderField: "User-Agent")
        // The reader has no browsing session with these sites and should not start building one:
        // cookies set by one article fetch would be sent back on the next, which is exactly the
        // cross-article profile the extraction is meant to avoid feeding.
        request.httpShouldHandleCookies = false
        return request
    }

    // MARK: - Decoding

    static let markupAccept = "text/html,application/xhtml+xml;q=0.9,*/*;q=0.8"

    static func isMarkup(_ contentType: String) -> Bool {
        // An absent Content-Type is treated as markup: it is a misconfigured server, not evidence
        // that the body is something else, and the extractor fails safely on anything it is not.
        guard !contentType.isEmpty else { return true }
        let lowered = contentType.lowercased()
        return lowered.contains("text/html")
            || lowered.contains("application/xhtml")
            || lowered.contains("text/plain")
    }

    /// Decodes the body, honouring the declared charset.
    ///
    /// Worth doing properly rather than assuming UTF-8: a Windows-1252 page decoded as UTF-8 fails
    /// outright, and the feeds most likely to be truncated are often the oldest ones.
    static func decode(_ data: Data, contentType: String) -> String? {
        if let name = charsetName(in: contentType), let text = decode(data, charsetNamed: name) {
            return text
        }
        if let text = String(data: data, encoding: .utf8) {
            return text
        }
        // A `<meta charset>` is only worth consulting once UTF-8 has failed, and reading it needs
        // *some* decoding first — Latin-1 never fails and gets the ASCII header right, which is all
        // the declaration itself is written in.
        if let latin = String(data: data, encoding: .isoLatin1) {
            if let name = charsetName(inMeta: latin), let text = decode(data, charsetNamed: name) {
                return text
            }
            return latin
        }
        return nil
    }

    private static func charsetName(in contentType: String) -> String? {
        guard let range = contentType.lowercased().range(of: "charset=") else { return nil }
        return contentType[range.upperBound...]
            .prefix { $0 != ";" && !$0.isWhitespace }
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }

    private static func charsetName(inMeta html: String) -> String? {
        let head = html.prefix(2048)
        if let range = head.range(of: "charset", options: .caseInsensitive) {
            let rest = head[range.upperBound...].drop { $0 == "=" || $0.isWhitespace || $0 == "\"" || $0 == "'" }
            let name = rest.prefix { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
            return name.isEmpty ? nil : String(name)
        }
        return nil
    }

    private static func decode(_ data: Data, charsetNamed name: String) -> String? {
        let encoding = CFStringConvertEncodingToNSStringEncoding(
            CFStringConvertIANACharSetNameToEncoding(name as CFString)
        )
        guard encoding != kCFStringEncodingInvalidId else { return nil }
        return String(data: data, encoding: String.Encoding(rawValue: encoding))
    }
}
