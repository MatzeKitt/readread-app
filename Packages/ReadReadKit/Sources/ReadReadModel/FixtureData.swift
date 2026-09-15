import Foundation
import SwiftData

/// Seed data for previews, the SwiftUI canvas, and running the app before any account is added.
///
/// This exists so the UI can be built and reviewed against realistic shapes — long titles, missing
/// favicons, HTML-laden excerpts, a Mastodon timeline mixed into an RSS river — rather than only
/// against whatever a live server happens to return today.
public enum FixtureData {

    public static let freshRSSAccountID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    public static let mastodonAccountID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    /// The device id fixture positions are attributed to.
    public static let deviceID = "fixture-device"

    /// Fills a context with a small but representative set of accounts, sources and items.
    ///
    /// - Parameter newerPerScope: How many items to leave above each scope's reading position.
    ///   A position part-way down the timeline is the state the app is almost always in, and it is
    ///   the only state in which the threshold UI can be reviewed at all — with no marker there is
    ///   no "N newer" to count, no position to scroll back to, and scroll tracking deliberately
    ///   refuses to commit.
    public static func seed(
        into context: ModelContext,
        itemsPerFeed: Int = 12,
        newerPerScope: Int = 6
    ) throws {
        context.insert(AccountRecord(
            id: freshRSSAccountID,
            kind: .freshRSS,
            displayName: "rss.example.net",
            serverURLString: "https://rss.example.net",
            username: "matze"
        ))
        context.insert(AccountRecord(
            id: mastodonAccountID,
            kind: .mastodon,
            displayName: "mastodon.social",
            serverURLString: "https://mastodon.social",
            username: "matze@mastodon.social"
        ))

        var now = Date.now.millisecondsSinceEpoch

        for (index, feed) in feeds.enumerated() {
            let sourceID = SourceIdentifier.freshRSS(accountID: freshRSSAccountID, streamID: feed.streamID)
            context.insert(CachedSource(
                id: sourceID,
                accountID: freshRSSAccountID,
                kind: .article,
                title: feed.title,
                homepageURLString: feed.homepage,
                iconURLString: feed.iconURL,
                folderName: feed.folder,
                sortIndex: index
            ))

            for offset in 0..<itemsPerFeed {
                // Stagger feeds so the unified timeline interleaves them the way a real river does.
                now -= Int64(1_000 * 60 * (7 + offset * 3 + index))
                let article = articles[(offset + index) % articles.count]
                let itemID = SourceIdentifier.freshRSSItem(
                    accountID: freshRSSAccountID,
                    itemID: "\(feed.streamID)-\(offset)"
                )
                let key = SortKey(millis: now, id: itemID)
                context.insert(CachedItem(
                    id: itemID,
                    sourceID: sourceID,
                    accountID: freshRSSAccountID,
                    folderName: feed.folder,
                    kind: .article,
                    title: article.title,
                    authorName: article.author,
                    urlString: "\(feed.homepage)/\(offset)",
                    contentHTML: article.html,
                    excerpt: article.excerpt,
                    publishedAt: Date(millisecondsSinceEpoch: now),
                    sortKey: key,
                    ingestKey: key,
                    iconURLString: feed.iconURL
                ))
            }
        }

        let homeID = SourceIdentifier.mastodonHome(accountID: mastodonAccountID)
        context.insert(CachedSource(
            id: homeID,
            accountID: mastodonAccountID,
            kind: .status,
            title: "Home",
            sortIndex: 0
        ))

        for offset in 0..<(itemsPerFeed * 2) {
            now -= Int64(1_000 * 60 * (3 + offset))
            let post = posts[offset % posts.count]
            let itemID = SourceIdentifier.mastodonItem(
                accountID: mastodonAccountID,
                statusID: "1099\(1000 + offset)"
            )
            let key = SortKey(millis: now, id: itemID)
            context.insert(CachedItem(
                id: itemID,
                sourceID: homeID,
                accountID: mastodonAccountID,
                kind: .status,
                title: post.plain,
                authorName: post.author,
                urlString: "https://mastodon.social/@\(post.handle)/1099\(1000 + offset)",
                contentHTML: post.html,
                excerpt: post.plain,
                publishedAt: Date(millisecondsSinceEpoch: now),
                sortKey: key,
                ingestKey: key,
                // Varied rather than constant, and some left at zero, so the timeline shows both
                // states the row has to handle: a post with reach, and one with none.
                replyCount: offset % 4 == 0 ? 0 : offset % 7,
                reblogCount: offset % 3 == 0 ? 0 : offset * 3 % 41,
                favouriteCount: offset % 5 == 0 ? 0 : offset * 7 % 137,
                // Every fourth post arrives as a boost, so the fixture timeline exercises the
                // footer with and without an attribution beside the counts. "" rather than nil on
                // the others: that is what a real ingest writes, and a fixture that leaves them
                // unanswered would be testing the pre-migration state instead.
                boostedByName: offset % 4 == 1 ? "Ada Lovelace" : "",
                mastodonPayload: statusPayload(
                    post: post,
                    statusID: "1099\(1000 + offset)",
                    publishedAt: Date(millisecondsSinceEpoch: now)
                )
            ))
        }

        try context.save()

        try seedPositions(into: context, newerPerScope: newerPerScope)
        try seedLateArrivals(into: context)

        try context.save()
    }

    /// Places every scope's marker `newerPerScope` items down from the top.
    private static func seedPositions(into context: ModelContext, newerPerScope: Int) throws {
        let sources = try context.fetch(FetchDescriptor<CachedSource>())

        var scopes: [ScopeID] = [.all]
        scopes.append(contentsOf: sources.map(\.scope))
        scopes.append(contentsOf: Set(sources.compactMap(\.folderName)).map(ScopeID.folder))

        for scope in scopes {
            var descriptor = FetchDescriptor<CachedItem>(
                predicate: ScopeQuery.displayPredicate(for: scope),
                sortBy: [SortDescriptor(\.sortKeyRaw, order: .reverse)]
            )
            descriptor.fetchOffset = newerPerScope
            descriptor.fetchLimit = 1
            guard let item = try context.fetch(descriptor).first else { continue }

            try ThresholdService.setPosition(scope, to: item.sortKey, deviceID: deviceID, in: context)
        }
    }

    /// Flags a few items that sit below the unified marker as having arrived late.
    ///
    /// The case the whole `arrivedLate` design exists for, and the only way to see the timeline's
    /// "older items arrived" affordance without waiting for a feed to backfill its archive.
    private static func seedLateArrivals(into context: ModelContext) throws {
        let mark = try ThresholdService.effectivePosition(for: .all, in: context).markSortKey.rawValue

        var descriptor = FetchDescriptor<CachedItem>(
            predicate: #Predicate { $0.sortKeyRaw < mark },
            sortBy: [SortDescriptor(\.sortKeyRaw, order: .reverse)]
        )
        descriptor.fetchLimit = 3
        for item in try context.fetch(descriptor) {
            item.arrivedLate = true
        }
    }

    /// A container pre-filled with fixtures, for previews.
    public static func previewContainer(itemsPerFeed: Int = 12) -> ModelContainer {
        do {
            let container = try ReadReadStore.inMemoryContainer()
            try seed(into: ModelContext(container), itemsPerFeed: itemsPerFeed)
            return container
        } catch {
            // A preview cannot recover from this and there is nothing useful to show without it,
            // so fail loudly rather than rendering a misleadingly empty UI.
            fatalError("Failed to build preview container: \(error)")
        }
    }

    // MARK: - Content

    private struct Feed {
        let streamID: String
        let title: String
        let folder: String
        let homepage: String
        let iconURL: String?
    }

    private static let feeds: [Feed] = [
        Feed(
            streamID: "feed/1",
            title: "Daring Fireball",
            folder: "Apple",
            homepage: "https://daringfireball.net",
            iconURL: "https://daringfireball.net/graphics/favicon-64.png"
        ),
        Feed(
            streamID: "feed/2",
            title: "Six Colors",
            folder: "Apple",
            homepage: "https://sixcolors.com",
            iconURL: nil
        ),
        Feed(
            streamID: "feed/3",
            title: "Swift by Sundell",
            folder: "Development",
            homepage: "https://swiftbysundell.com",
            iconURL: nil
        ),
        Feed(
            streamID: "feed/4",
            title: "A feed with a deliberately very long title that has to truncate somewhere",
            folder: "Development",
            homepage: "https://example.com",
            iconURL: nil
        ),
    ]

    private struct Article {
        let title: String
        let author: String?
        let html: String
        var excerpt: String { HTMLTextPreview.excerpt(from: html) }
    }

    private static let articles: [Article] = [
        Article(
            title: "On the new design language",
            author: "John Gruber",
            html: """
            <p>The most interesting thing about the redesign is not the material itself but what it
            implies about hierarchy. When every surface can refract what is behind it, depth stops
            being decoration and starts carrying meaning.</p>
            <p>That is a real constraint on layout, and a welcome one.</p>
            """
        ),
        Article(
            title: "A short one",
            author: nil,
            html: "<p>Sometimes an item has almost no content at all.</p>"
        ),
        Article(
            title: "Concurrency, revisited: what strict mode actually changed in practice",
            author: "John Sundell",
            html: """
            <p>Strict concurrency checking does not make your code correct. It makes the places
            where correctness was previously <em>assumed</em> into places where it has to be
            <strong>stated</strong>.</p>
            <ul><li>Actors for mutable state</li><li>Sendable at the boundaries</li>
            <li>and a great deal of thinking about who owns what</li></ul>
            <p>The result reads better even where it is more verbose.</p>
            """
        ),
        Article(
            title: "Notes from a week of testing background refresh",
            author: "Jason Snell",
            html: """
            <p>The scheduler is not a timer. Treating it as one is the single most common reason
            people conclude background refresh is broken.</p>
            <blockquote>Submit the next request at the end of every run, or it fires exactly
            once.</blockquote>
            """
        ),
    ]

    /// A `MastodonStatus` payload for a fixture post.
    ///
    /// Written as JSON rather than built from the API types because `ReadReadModel` does not depend
    /// on `MastodonAPI` — and should not, for a fixture. The wire format is the contract here, so
    /// generating it this way also means the fixtures exercise the real decoder.
    private static func statusPayload(post: Post, statusID: String, publishedAt: Date) -> Data {
        let timestamp = ISO8601DateFormatter.fixtureFormatter().string(from: publishedAt)
        let json = """
        {
          "id": "\(statusID)",
          "uri": "https://mastodon.social/users/\(post.handle)/statuses/\(statusID)",
          "created_at": "\(timestamp)",
          "account": {
            "id": "1",
            "username": "\(post.handle)",
            "acct": "\(post.handle)@mastodon.social",
            "display_name": "\(post.author)",
            "avatar": "",
            "url": "https://mastodon.social/@\(post.handle)",
            "bot": false,
            "emojis": []
          },
          "content": "\(jsonEscaped(post.html))",
          "visibility": "public",
          "sensitive": false,
          "spoiler_text": "",
          "media_attachments": [],
          "reblog": null,
          "in_reply_to_id": null,
          "in_reply_to_account_id": null,
          "url": "https://mastodon.social/@\(post.handle)/\(statusID)",
          "poll": \(post.pollJSON ?? "null"),
          "emojis": \(post.emojisJSON),
          "card": null,
          "tags": [],
          "mentions": [],
          "replies_count": 0,
          "reblogs_count": 0,
          "favourites_count": 0,
          "edited_at": null,
          "language": "en"
        }
        """
        return Data(json.utf8)
    }

    /// Escapes a string for embedding in the JSON above.
    ///
    /// The fixture HTML is written as multi-line Swift literals, and a raw newline inside a JSON
    /// string is simply invalid — which made two of the three fixture posts fail to decode while
    /// still rendering fine, because the status view falls back to the plain columns.
    private static func jsonEscaped(_ text: String) -> String {
        var escaped = ""
        for character in text {
            switch character {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            default: escaped.append(character)
            }
        }
        return escaped
    }

    private struct Post {
        let author: String
        let handle: String
        let html: String

        /// This post's poll, as the JSON object Mastodon would send, or `nil` for no poll.
        ///
        /// Without a payload the status view falls back to the plain columns, so a poll is
        /// unreachable in fixtures otherwise.
        var pollJSON: String?

        /// Custom emoji, as the JSON array Mastodon would send.
        var emojisJSON: String = "[]"

        var plain: String { HTMLTextPreview.plainText(from: html) }
    }

    private static let posts: [Post] = [
        Post(
            author: "Radiant Spindle",
            handle: "spindle",
            html: "<p>Shipping a feed reader means discovering how many ways a date can be wrong.</p>"
        ),
        Post(
            author: "Poll Bot :blobcat:",
            handle: "pollbot",
            html: "<p>Which ordering should a reader default to? :blobcat: :rust:</p>",
            pollJSON: """
            {
              "id": "42",
              "expires_at": "2099-01-01T00:00:00.000Z",
              "expired": false,
              "multiple": false,
              "votes_count": 137,
              "voters_count": 137,
              "options": [
                { "title": "Published date", "votes_count": 96 },
                { "title": "When it arrived", "votes_count": 34 },
                { "title": "Whatever the server says", "votes_count": 7 }
              ]
            }
            """,
            emojisJSON: """
            [
              { "shortcode": "blobcat", "url": "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAANElEQVR42mP4tUWDgRKMTfA/AYzXgP9EYqwG/CcRoxjwn0w8asDwMoDihESVpEyVzEQyBgC/C4FzlFzsGgAAAABJRU5ErkJggg==", "static_url": null, "visible_in_picker": true },
              { "shortcode": "rust", "url": "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAANElEQVR42mM44abBQAnGJvifAMZrwH8iMVYD/pOIUQz4TyYeNWB4GUBxQqJKUqZKZiIZAwAqAOFkC8aR4QAAAABJRU5ErkJggg==", "static_url": null, "visible_in_picker": true }
            ]
            """
        ),
        Post(
            author: "Ada L.",
            handle: "ada",
            html: """
            <p>Reminder that &ldquo;sort by published date&rdquo; and &ldquo;sort by when it
            arrived&rdquo; are different questions, and mixing them up is why your reader keeps
            hiding posts.</p>
            """
        ),
        Post(
            author: "kittmedia",
            handle: "kittmedia",
            html: "<p>Three columns, arrow keys, and a badge that tells the truth. That is the whole brief.</p>"
        ),
    ]
}

/// Minimal local copy of the excerpt helpers.
///
/// `ReadReadModel` deliberately does not depend on the HTML utilities for its production types —
/// excerpts are computed during ingest, in the provider modules — and fixtures should not be the
/// reason to add a dependency edge that nothing else needs.
private enum HTMLTextPreview {

    static func plainText(from html: String) -> String {
        var output = ""
        var insideTag = false
        for character in html {
            switch character {
            case "<": insideTag = true
            case ">": insideTag = false
            default: if !insideTag { output.append(character) }
            }
        }
        return output
            .replacingOccurrences(of: "&ldquo;", with: "“")
            .replacingOccurrences(of: "&rdquo;", with: "”")
            .replacingOccurrences(of: "&amp;", with: "&")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    static func excerpt(from html: String, limit: Int = 320) -> String {
        let text = plainText(from: html)
        guard text.count > limit else { return text }
        return text.prefix(limit) + "…"
    }
}

private extension ISO8601DateFormatter {

    /// Matches what Mastodon sends, which the app's decoder expects: fractional seconds and a Z.
    ///
    /// Built per call rather than shared: `ISO8601DateFormatter` is not `Sendable`, and this runs
    /// a few dozen times at fixture-seeding and never again.
    static func fixtureFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}
