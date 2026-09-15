import Foundation

// Wire types for the Mastodon REST API.
//
// Decoded with `.convertFromSnakeCase`, so property names mirror the JSON keys directly. That is
// why some read as `inReplyToId` rather than `inReplyToID`: these are boundary types, and matching
// the wire exactly is worth more here than Swift naming conventions, because a silently-unmatched
// key decodes as nil instead of failing.
//
// Nullability follows the documented entity definitions rather than being defensive: a field is
// optional here only where the API says it can be null.

/// A status — a post, or a boost wrapping one.
///
/// A `final class` rather than a struct because `reblog` makes the type recursive, and a class is
/// a plainer way to express that than boxing every status in an indirect wrapper. All properties
/// are `let`, so it is still a value in practice.
public final class MastodonStatus: Codable, Sendable {

    public let id: MastodonStatusID
    public let uri: String
    public let createdAt: Date
    public let account: MastodonAccount

    /// Sanitised HTML. Mastodon restricts this to a small tag set — `<p>`, `<br>`, `<a>`,
    /// `<span>` — which is what makes native rendering practical.
    public let content: String

    public let visibility: String
    public let sensitive: Bool

    /// Content-warning text. Empty rather than null when absent.
    public let spoilerText: String

    public let mediaAttachments: [MastodonMediaAttachment]

    /// The boosted status, when this status is a boost.
    ///
    /// A boost carries its *own* `id` and `createdAt` — the moment of boosting — while the content
    /// belongs to the inner status. Both matter: the timeline is ordered by the boost's time, but
    /// the body and author shown are the original's.
    public let reblog: MastodonStatus?

    public let inReplyToId: String?
    public let inReplyToAccountId: String?
    public let url: String?
    public let poll: MastodonPoll?
    public let card: MastodonPreviewCard?
    public let emojis: [MastodonCustomEmoji]
    public let tags: [MastodonTag]
    public let mentions: [MastodonMention]
    public let repliesCount: Int
    public let reblogsCount: Int
    public let favouritesCount: Int

    /// Whether the account whose token fetched this has favourited it, and whether it has boosted
    /// it.
    ///
    /// Documented as null on an unauthenticated request, which is why they are optional. Every
    /// fetch this app makes carries a token, so in practice these are the reader's own state — and
    /// they are what lets the timeline offer *Unlike* rather than a second Like.
    ///
    /// They belong to the account that asked. A post fetched by one account says nothing about
    /// whether another of the reader's accounts has favourited it, which is the limit acting as a
    /// different account runs into.
    public let favourited: Bool?
    public let reblogged: Bool?

    public let editedAt: Date?
    public let language: String?

    // MARK: Derived

    /// The status whose content should be displayed — the boosted one, if this is a boost.
    public var displayStatus: MastodonStatus { reblog ?? self }

    public var isBoost: Bool { reblog != nil }

    /// Who boosted, when this is a boost.
    public var boostedBy: MastodonAccount? { reblog == nil ? nil : account }
}

/// A status's conversation: what came before it, and what came after.
public struct MastodonStatusContext: Codable, Sendable {

    /// The chain up to the root, oldest first — so rendering them in order reads as a conversation
    /// arriving at the status being viewed.
    public let ancestors: [MastodonStatus]

    /// Replies, flattened. Mastodon returns the whole subtree in one array rather than a tree; the
    /// reply structure is recoverable from each status's `inReplyToId` where it matters.
    public let descendants: [MastodonStatus]

    public init(ancestors: [MastodonStatus], descendants: [MastodonStatus]) {
        self.ancestors = ancestors
        self.descendants = descendants
    }
}

public struct MastodonAccount: Codable, Sendable {

    public let id: String
    public let username: String

    /// `user` locally, `user@host` for a remote account. The form to show, since `username` alone
    /// is ambiguous across instances.
    public let acct: String

    public let displayName: String
    public let avatar: String

    /// Non-animated avatar, used when the viewer has asked to reduce motion.
    public let avatarStatic: String?

    public let url: String
    public let bot: Bool?
    public let emojis: [MastodonCustomEmoji]?

    /// The best label for this account: display name if set, otherwise the handle.
    ///
    /// Many accounts leave `display_name` empty, and a blank byline looks broken.
    public var bestDisplayName: String {
        displayName.isEmpty ? "@\(acct)" : displayName
    }

    public var avatarURLString: String {
        avatarStatic ?? avatar
    }
}

public struct MastodonMediaAttachment: Codable, Sendable {

    public let id: String

    /// `unknown`, `image`, `gifv`, `video` or `audio`.
    public let type: String

    /// Null while the server is still processing the upload.
    public let url: String?

    public let previewUrl: String?
    public let remoteUrl: String?

    /// Alt text. Rendered as the accessibility label.
    public let description: String?

    /// BlurHash, for a placeholder whose colours match the image while it loads.
    public let blurhash: String?

    public let meta: MastodonAttachmentMeta?

    /// The URL worth loading for a grid thumbnail, preferring the scaled version.
    public var thumbnailURLString: String? {
        previewUrl ?? url ?? remoteUrl
    }

    public var fullURLString: String? {
        url ?? remoteUrl
    }
}

public struct MastodonAttachmentMeta: Codable, Sendable {

    public let original: MastodonAttachmentSize?
    public let small: MastodonAttachmentSize?

    /// Focal point for smart cropping, when the uploader set one.
    public let focus: MastodonAttachmentFocus?
}

public struct MastodonAttachmentSize: Codable, Sendable {
    public let width: Int?
    public let height: Int?

    /// Width over height. Used to reserve the right amount of space before the image loads, so
    /// the timeline does not jump as attachments arrive.
    public let aspect: Double?
}

public struct MastodonAttachmentFocus: Codable, Sendable {
    public let x: Double?
    public let y: Double?
}

public struct MastodonCustomEmoji: Codable, Sendable {
    public let shortcode: String
    public let url: String
    public let staticUrl: String?
    public let visibleInPicker: Bool?
}

public struct MastodonTag: Codable, Sendable {
    public let name: String
    public let url: String
}

public struct MastodonMention: Codable, Sendable {
    public let id: String
    public let username: String
    public let url: String
    public let acct: String
}

public struct MastodonPoll: Codable, Sendable {

    public let id: String
    public let expiresAt: Date?
    public let expired: Bool
    public let multiple: Bool
    public let votesCount: Int
    public let votersCount: Int?
    public let options: [Option]
    public let voted: Bool?
    public let ownVotes: [Int]?

    public struct Option: Codable, Sendable {
        public let title: String

        /// Null until the poll ends, when the server hides running tallies.
        public let votesCount: Int?
    }
}

public struct MastodonPreviewCard: Codable, Sendable {
    public let url: String
    public let title: String
    public let description: String
    public let type: String
    public let image: String?
    public let providerName: String?
}

/// Response of `GET /api/v2/search`.
///
/// Only the statuses are decoded. The endpoint answers with accounts and hashtags in the same
/// object, and the one use here is resolving a post's URL to whatever id the *acting* instance
/// files it under — which is the only way one account can act on a post another account fetched.
public struct MastodonSearchResults: Decodable, Sendable {
    public let statuses: [MastodonStatus]
}

/// Response of `POST /api/v1/apps`.
public struct MastodonApplication: Decodable, Sendable {

    public let id: String?
    public let name: String
    public let clientId: String
    public let clientSecret: String

    /// Added in 4.3. Older servers send only the deprecated singular `redirect_uri`.
    public let redirectUris: [String]?
    public let redirectUri: String?
}

/// Response of `POST /oauth/token`.
public struct MastodonTokenResponse: Decodable, Sendable {

    public let accessToken: String
    public let tokenType: String
    public let scope: String

    /// Seconds since the epoch. Mastodon access tokens do not expire, so this is informational.
    public let createdAt: Double?
}

/// Response of `GET /api/v1/accounts/verify_credentials`.
public struct MastodonCredentialAccount: Decodable, Sendable {
    public let id: String
    public let username: String
    public let acct: String
    public let displayName: String
    public let avatar: String
    public let url: String
}

// MARK: - Decoding

public extension JSONEncoder {

    /// Encodes back into the API's own shape.
    ///
    /// Exists so a decoded status can be stored verbatim on `CachedItem.mastodonPayload` and
    /// decoded again by the detail view. The key and date strategies are the exact inverses of
    /// ``JSONDecoder/mastodon``; if they ever diverge, a stored payload becomes undecodable.
    static var mastodon: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(date))
        }
        return encoder
    }
}

public extension JSONDecoder {

    /// A decoder configured for the Mastodon API.
    static var mastodon: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            guard let date = MastodonDate.parse(raw) else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "Unparseable date '\(raw)'")
                )
            }
            return date
        }
        return decoder
    }
}

/// Parses the timestamp formats the API actually emits.
///
/// The documented example is `2019-12-08T03:48:33.901Z` — ISO 8601 **with fractional seconds**,
/// which `JSONDecoder.DateDecodingStrategy.iso8601` rejects outright. Other implementations and
/// some endpoints omit the fraction, and `Poll.expires_at` has been seen with an offset rather than
/// `Z`. Trying each in turn is the only thing that works across all of them.
enum MastodonDate {

    // `Date.ISO8601FormatStyle` rather than `ISO8601DateFormatter`: the formatter is a
    // non-`Sendable` class, so caching one in a `static let` is not concurrency-safe, and creating
    // one per date would allocate twice for every timestamp in every page. The format style is a
    // value type and `Sendable`, so it can simply be a constant.
    private static let withFractionalSeconds = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let withoutFractionalSeconds = Date.ISO8601FormatStyle()

    static func parse(_ raw: String) -> Date? {
        // Fractional first: it is what the documented format uses, so it is the common case.
        if let date = try? withFractionalSeconds.parse(raw) { return date }
        if let date = try? withoutFractionalSeconds.parse(raw) { return date }
        return parseDateOnly(raw)
    }

    /// Parses a bare `yyyy-MM-dd`, which some implementations use for `Poll.expires_at`.
    ///
    /// Hand-rolled rather than reaching for a `DateFormatter`, which has the same `Sendable`
    /// problem. Worth handling at all because the decoder treats an unparseable date as a hard
    /// failure, so one odd poll timestamp would otherwise reject the entire status containing it.
    private static func parseDateOnly(_ raw: String) -> Date? {
        let parts = raw.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1...12).contains(month), (1...31).contains(day)
        else { return nil }

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.timeZone = TimeZone(secondsFromGMT: 0)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: components)
    }
}
