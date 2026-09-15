import Foundation

/// A Mastodon entity id.
///
/// ## Why this is not an integer
///
/// The API guidelines are explicit: *"Always treat IDs as opaque strings"*, and warn that casting
/// them risks overflow or outright errors. Vanilla Mastodon happens to use Snowflake-derived
/// numeric strings, but the API is implemented by GoToSocial, Akkoma and others that use base-62
/// values, ULIDs, or URI-shaped ids. Parsing to `UInt64` would work against mastodon.social and
/// fail against a self-hosted instance — the worst kind of bug, because it depends on whose server
/// the user picked.
///
/// ## Ordering
///
/// The walk needs to compare ids to decide when it has reached already-known items, so ordering has
/// to be defined. The guidelines prescribe **length first, then lexically**: "newer IDs will have
/// greater length or higher digit values". That is correct for numeric strings of differing length —
/// where plain lexicographic order would put `"9999"` above `"10000"` and make the stop line skip
/// most of a page — and it is also correct for lexically-sortable schemes like ULIDs.
public struct MastodonStatusID: Hashable, Sendable, Comparable, CustomStringConvertible {

    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }

    public var isEmpty: Bool { rawValue.isEmpty }

    /// Length first, then lexicographic.
    ///
    /// An empty id sorts below everything, which is what makes it usable as "no stop line yet".
    public static func < (lhs: MastodonStatusID, rhs: MastodonStatusID) -> Bool {
        if lhs.rawValue.count != rhs.rawValue.count {
            return lhs.rawValue.count < rhs.rawValue.count
        }
        return lhs.rawValue < rhs.rawValue
    }
}

extension MastodonStatusID: Codable {

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
