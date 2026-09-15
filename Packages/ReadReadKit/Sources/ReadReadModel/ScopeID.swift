import Foundation

/// Identifies a place a reading position can be remembered.
///
/// Every scope has a threshold of its own, but they are not independent: scopes overlap, so a
/// scroll propagates along containment — see ``ThresholdService/setPositionCascading(_:to:deviceID:in:)``.
/// The string form is what travels through the sync endpoint and what keys `PositionMark`, so it
/// has to round-trip exactly; `RawRepresentable` conformance is the single definition of that
/// mapping.
public enum ScopeID: Hashable, Sendable, Codable, RawRepresentable {

    /// The unified timeline across every account and source.
    case all

    /// A FreshRSS category/folder, addressed by name because that is what the Google Reader API
    /// exposes as a stream id (`user/-/label/<name>`); FreshRSS has no stable numeric id for a
    /// label in that payload.
    case folder(String)

    /// A single feed or Mastodon timeline, addressed by `CachedSource.id`.
    case source(String)

    /// A Mastodon account's home timeline.
    case mastodonHome(accountID: UUID)

    /// The Read Later list. It has a position too, so opening it does not always dump you at the
    /// top of a long backlog.
    case readLater

    /// Items that arrived carrying a published date below their scope's marker.
    ///
    /// A scope in its own right so it can be a sidebar list, but not a *positioned* one: it has no
    /// threshold to scroll through, because every item in it is by definition sitting below one
    /// already. Its badge is a plain count of what is waiting, and the list empties as items are
    /// dismissed rather than as a marker moves through it.
    case lateArrivals

    /// Everything the filter rules are currently hiding.
    ///
    /// A scope for the same reason ``lateArrivals`` is one — so it can be a sidebar list — and
    /// unpositioned for the same reason too. Nobody *reads* through the filtered pile; it is where
    /// you go when a feed has gone quiet and you want to know whether a pattern is too broad. So
    /// its count is a plain total of what is hidden, and it propagates no position in either
    /// direction.
    case filtered

    // MARK: - RawRepresentable

    private enum Prefix {
        static let folder = "folder:"
        static let source = "source:"
        static let mastodonHome = "mastodon-home:"
    }

    public init?(rawValue: String) {
        switch rawValue {
        case "all":
            self = .all
        case "read-later":
            self = .readLater
        case "late-arrivals":
            self = .lateArrivals
        case "filtered":
            self = .filtered
        default:
            if let name = rawValue.dropping(prefix: Prefix.folder) {
                // A folder name is free text and may itself contain a colon, so the remainder is
                // taken wholesale rather than split on the separator.
                self = .folder(name)
            } else if let id = rawValue.dropping(prefix: Prefix.source) {
                self = .source(id)
            } else if let id = rawValue.dropping(prefix: Prefix.mastodonHome),
                      let uuid = UUID(uuidString: id) {
                self = .mastodonHome(accountID: uuid)
            } else {
                return nil
            }
        }
    }

    public var rawValue: String {
        switch self {
        case .all:
            "all"
        case .readLater:
            "read-later"
        case .lateArrivals:
            "late-arrivals"
        case .filtered:
            "filtered"
        case .folder(let name):
            Prefix.folder + name
        case .source(let id):
            Prefix.source + id
        case .mastodonHome(let accountID):
            Prefix.mastodonHome + accountID.uuidString
        }
    }

    // MARK: - Codable

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let scope = ScopeID(rawValue: raw) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Unrecognised scope id '\(raw)'")
            )
        }
        self = scope
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension StringProtocol {

    /// Returns the remainder after `prefix`, or `nil` when the prefix is absent.
    ///
    /// Distinguishing "prefix absent" from "prefix present, remainder empty" matters here:
    /// `source:` with nothing after it is malformed input, not a valid scope.
    func dropping(prefix: String) -> String? {
        guard hasPrefix(prefix), count > prefix.count else { return nil }
        return String(dropFirst(prefix.count))
    }
}
