import Foundation
import ReadReadSupport

/// Fetches the comments on an article from the site that published it.
///
/// The sibling of ``FullPageFetcher``, and turned on the same way — per feed, through
/// ``CachedSource/loadsComments`` — for the same reason: it costs requests against somebody else's
/// server, and whether a feed's articles have a discussion worth reading is a property of the
/// publisher that no single item reveals.
///
/// Two requests on the first open of an article and one on each open after that: the page, to find
/// out where the comments live, and then the comments. ``Discovery`` is what the caller keeps so
/// the first of those is not repeated.
public struct CommentsFetcher: Sendable {

    /// What an article's page had to offer.
    public struct Discovery: Sendable, Equatable {

        /// The REST collection this post's comments can be read from, when the site advertises one.
        public var endpoint: WordPressComments.Endpoint?

        /// The discussion as the page itself rendered it, reduced to the comments — the fallback
        /// for a site whose REST API is switched off or filtered.
        public var markup: String?

        public init(endpoint: WordPressComments.Endpoint? = nil, markup: String? = nil) {
            self.endpoint = endpoint
            self.markup = markup
        }

        /// Whether this page offers comments at all.
        public var isEmpty: Bool { endpoint == nil && markup == nil }
    }

    public enum Outcome: Sendable, Equatable {
        /// The discussion as data, nested. Empty means the post has no comments — a real answer,
        /// and a different thing from ``unsupported``.
        case threads([WordPressCommentNode])

        /// The page's own comment markup, for a site that would not serve the data.
        case markup(String)

        /// Not a WordPress page, or one with no discussion anywhere in it. A final answer, like
        /// ``FullPageFetcher/Outcome/unusable``, not a failure worth retrying.
        case unsupported
    }

    public enum Failure: Error, Sendable, Equatable {
        case notAWebPage(contentType: String)
        case tooLarge(bytes: Int)
        case undecodableText
    }

    /// The most comments to read for one article, as five pages of a hundred.
    ///
    /// Bounded because a popular post's discussion is unbounded and this all ends up in a reading
    /// pane: a thread of nine thousand comments is neither renderable nor readable, and fetching it
    /// would hold ninety requests' worth of a stranger's server. Five hundred is past the point
    /// where anyone is still reading in order.
    static let maximumPages = 5

    private let client: HTTPClient
    private let timeout: TimeInterval

    public init(transport: any HTTPTransport = URLSession.shared, timeout: TimeInterval = 20) {
        // The same impatience as the full-page fetch, and for the same reason: this runs while the
        // article is already on screen waiting for its discussion to appear beneath it.
        client = HTTPClient(transport: transport, policy: .impatient)
        self.timeout = timeout
    }

    // MARK: - Whole fetch

    /// Discovers and loads an article's comments in one go.
    public func fetch(_ url: URL) async throws -> Outcome {
        let discovery = try await discover(url)
        return try await comments(using: discovery, at: url)
    }

    /// Loads comments from a discovery made earlier, so re-opening an article costs one request.
    ///
    /// Falls back to the page markup the discovery captured when the API will not answer. The
    /// fallback is inside this method rather than at the call site because the caller cannot tell
    /// a filtered endpoint from a broken one, and either way the answer is the same: show what the
    /// page had.
    public func comments(using discovery: Discovery, at url: URL) async throws -> Outcome {
        if let endpoint = discovery.endpoint {
            // Errors are swallowed *here only*, and only to reach the fallback: a site that turns
            // the comments endpoint off answers 401, 403 or 404, which is a configuration rather
            // than something gone wrong.
            if let comments = try? await self.comments(at: endpoint) {
                // An empty API answer alongside real markup on the page is not "no comments", it
                // is an endpoint that will not talk about them. The page is the better witness.
                if !comments.isEmpty || discovery.markup == nil {
                    return .threads(WordPressComment.trees(from: comments))
                }
            }
        }
        if let markup = discovery.markup {
            return .markup(markup)
        }
        return .unsupported
    }

    // MARK: - Discovery

    /// Fetches an article's page and works out where its comments are.
    public func discover(_ url: URL) async throws -> Discovery {
        let html = try await page(at: url)
        return Discovery(
            endpoint: WordPressComments.endpoint(in: html, baseURL: url),
            markup: WordPressComments.markup(in: html, baseURL: url)
        )
    }

    private func page(at url: URL) async throws -> String {
        let reply = try await client.reply(
            for: FullPageFetcher.pageRequest(for: url, timeout: timeout)
        )

        let contentType = reply.header("Content-Type") ?? ""
        guard FullPageFetcher.isMarkup(contentType) else {
            throw Failure.notAWebPage(contentType: contentType)
        }
        guard reply.data.count <= FullPageFetcher.maximumBytes else {
            throw Failure.tooLarge(bytes: reply.data.count)
        }
        guard let html = FullPageFetcher.decode(reply.data, contentType: contentType) else {
            throw Failure.undecodableText
        }
        return html
    }

    // MARK: - REST

    /// Every comment on the post, oldest first, across as many pages as the cap allows.
    public func comments(at endpoint: WordPressComments.Endpoint) async throws -> [WordPressComment] {
        var collected: [WordPressComment] = []
        var page = 1

        while page <= Self.maximumPages {
            guard let url = endpoint.requestURL(page: page) else { break }

            var request = URLRequest(url: url, timeoutInterval: timeout)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("ReadRead/1.0 (feed reader; +https://github.com/kittmedia/readread)",
                             forHTTPHeaderField: "User-Agent")
            // Same reasoning as the page fetch: this app has no session with the site and must not
            // start one. It also means the API answers as the public does, which is the set of
            // comments the reader would see in a browser they were not logged into.
            request.httpShouldHandleCookies = false

            // Non-2xx already throws out of `reply(for:)` — which is what a site with the
            // comments endpoint disabled answers, and what sends `comments(using:at:)` to the
            // page markup instead.
            let reply = try await client.reply(for: request)

            let resources = try JSONDecoder().decode([CommentResource].self, from: reply.data)
            collected.append(contentsOf: resources.compactMap { $0.comment(baseURL: url) })

            // The server's own count of pages, so paging stops without a request that 400s past
            // the end. An absent header means a single page — which is what a site with the
            // header stripped by a proxy also looks like, and one page is the safer reading.
            guard let total = reply.header("X-WP-TotalPages").flatMap(Int.init), page < total else {
                break
            }
            page += 1
        }

        return collected
    }
}

// MARK: - Wire shape

/// One comment as `wp/v2/comments` returns it.
///
/// Hand-written `CodingKeys` rather than `convertFromSnakeCase`, because two of these keys are the
/// ones that strategy gets wrong in a way that compiles: `author_url` becomes `authorUrl` and
/// `date_gmt` becomes `dateGmt`, so a property spelled the way Swift would spell it silently
/// decodes as nil.
private struct CommentResource: Decodable {

    var id: Int
    var parent: Int?
    var authorName: String?
    var authorURL: String?
    var authorAvatarURLs: AvatarURLs?
    var dateGMT: String?
    var content: RenderedContent?

    enum CodingKeys: String, CodingKey {
        case id
        case parent
        case authorName = "author_name"
        case authorURL = "author_url"
        case authorAvatarURLs = "author_avatar_urls"
        case dateGMT = "date_gmt"
        case content
    }

    struct RenderedContent: Decodable {
        var rendered: String?
    }

    /// The avatar sizes WordPress offers, or nothing.
    ///
    /// Its own type because the field is not one shape: it is an object of size-to-URL on a normal
    /// install, an empty object when the comment has no avatar, and `false` when avatars are turned
    /// off site-wide. A plain `[String: String]?` decodes the first two and throws on the third,
    /// which would reject the whole comment — and with it the whole page of comments — over a
    /// picture.
    enum AvatarURLs: Decodable {
        case sizes([String: String])
        case unavailable

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let sizes = try? container.decode([String: String].self) {
                self = .sizes(sizes)
            } else {
                self = .unavailable
            }
        }

        /// The largest size offered, which is the one worth having: these are drawn at a fixed
        /// size in the reading pane and the 24-pixel variant is visibly soft on any modern display.
        var largest: String? {
            guard case .sizes(let sizes) = self else { return nil }
            return sizes
                .compactMap { key, value in Int(key).map { ($0, value) } }
                .max { $0.0 < $1.0 }?
                .1
        }
    }

    /// The reader's own value, or `nil` for a resource with nothing to show.
    ///
    /// Returns nil rather than throwing: one malformed comment in a page of ninety should cost
    /// that comment, not the page.
    func comment(baseURL: URL?) -> WordPressComment? {
        guard let raw = content?.rendered else { return nil }

        // Sanitised here, at the boundary, so no un-sanitised comment body ever exists as a value
        // this app could pass on by mistake. See ``HTMLSanitizer`` — a comment is markup a stranger
        // typed into a third party's website, which makes it the least trustworthy HTML the reader
        // renders.
        let sanitised = HTMLSanitizer.sanitize(HTMLParser.parse(raw), baseURL: baseURL)
        guard let publishedAt = dateGMT.flatMap(WordPressDate.parse) else { return nil }

        return WordPressComment(
            id: id,
            parentID: parent ?? 0,
            authorName: Self.nonEmpty(authorName) ?? String(localized: "Anonymous"),
            authorURLString: Self.nonEmpty(authorURL),
            avatarURLString: authorAvatarURLs?.largest,
            publishedAt: publishedAt,
            contentHTML: sanitised
        )
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
        else { return nil }
        return trimmed
    }
}

/// Parses the timestamps `wp/v2/comments` emits.
///
/// `date_gmt` is ISO 8601 **with no zone designator** — `2026-09-01T09:12:00` — because WordPress
/// puts the zone in the field's name instead. `Date.ISO8601FormatStyle()` requires the designator
/// and rejects it outright, so reading these as UTC has to be asked for explicitly. Getting this
/// wrong is not a parse failure but a silent shift of every comment by the reader's own offset,
/// which is precisely the kind of bug that looks like the server being odd.
enum WordPressDate {

    // Value types rather than a `DateFormatter`, for the reason `MastodonDate` gives: the formatter
    // is a non-`Sendable` class, so it can be neither cached in a `static let` nor created cheaply
    // enough to make per-comment allocation reasonable.
    private static let zoneless = Date.ISO8601FormatStyle(timeZone: .gmt)
        .year().month().day()
        .dateTimeSeparator(.standard)
        .time(includingFractionalSeconds: false)

    private static let zoned = Date.ISO8601FormatStyle()

    static func parse(_ raw: String) -> Date? {
        // Zone-less first: it is what `date_gmt` is, so it is the case that always happens.
        if let date = try? zoneless.parse(raw) { return date }
        // A site behind a plugin that normalises timestamps, or a future core version that adds
        // the designator. Cheap to accept and expensive to have not accepted.
        return try? zoned.parse(raw)
    }
}
