import Foundation

/// A total, stable ordering key for feed items.
///
/// Two things make this a distinct type rather than a `(Date, String)` tuple:
///
/// 1. **It compares correctly as a plain `String`.** The millisecond component is zero-padded to a
///    fixed width, so lexicographic order and numeric order agree. That is what lets the "items
///    newer than the threshold" query be a `fetchCount` with a simple `sortKey > mark` predicate
///    inside a SwiftData `#Predicate`, which cannot express a compound `(date, id)` comparison.
/// 2. **It breaks ties deterministically.** Two items published in the same millisecond would
///    otherwise have an unstable relative order, which would make a position marker ambiguous.
///
/// The millisecond component is the item's *published* date, so the timeline reads chronologically
/// and recently-fetched old content does not float to the top. `CachedItem.ingestKey` separately
/// records when an item arrived, for late-arrival detection and retention.
public struct SortKey: Hashable, Sendable, Comparable, Codable, CustomStringConvertible {

    /// Width of the millisecond field. 13 digits spans epoch through year 2286, which comfortably
    /// outlives any feed, and a fixed width is what makes string comparison valid.
    static let millisDigits = 13

    /// Largest value representable in `millisDigits` digits.
    static let maxMillis: Int64 = 9_999_999_999_999

    /// Separator between the two fields. `|` sorts above every character that can appear in an
    /// item id (which are hex, decimal, or URL-safe), so a key with an empty id never sorts
    /// *between* two keys that share its timestamp.
    static let separator: Character = "|"

    public let rawValue: String

    // MARK: - Creation

    /// Wraps a previously-serialised key. Used when reading back from storage or the sync payload.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// - Parameters:
    ///   - millis: Milliseconds since the epoch. Values outside the representable range are
    ///     clamped rather than rejected: a feed serving a nonsensical date should sort at one end
    ///     of the timeline, not fail the whole ingest of the page it arrived in.
    ///   - id: The item's stable identifier, used only to break same-millisecond ties.
    public init(millis: Int64, id: String) {
        let clamped = min(max(millis, 0), Self.maxMillis)
        let padded = String(format: "%0\(Self.millisDigits)lld", clamped)
        rawValue = "\(padded)\(Self.separator)\(id)"
    }

    public init(date: Date, id: String) {
        self.init(millis: date.millisecondsSinceEpoch, id: id)
    }

    // MARK: - Sentinels

    /// Sorts below every real key. The effective marker for a scope that has never been read, so
    /// that "newer than the marker" counts everything.
    public static let distantPast = SortKey(rawValue: "")

    /// Sorts above every real key. Used to mark a scope fully caught up regardless of what
    /// arrives later in the same millisecond.
    ///
    /// The id component is `~` (U+007E) repeated: deliberately plain ASCII, and above every
    /// character that can occur in a real item id (hex, decimal, and URL-safe ids all top out at
    /// `z`, U+007A). A non-ASCII sentinel would be riskier than it looks — these keys are also
    /// compared by SQLite inside SwiftData predicates, and only for pure ASCII is every collation
    /// guaranteed to agree with Swift's in-memory `String` ordering.
    public static let distantFuture = SortKey(
        rawValue: String(repeating: "9", count: millisDigits)
            + String(separator)
            + String(repeating: "~", count: 8)
    )

    // MARK: - Components

    /// The millisecond component, or `nil` for a sentinel that has no meaningful timestamp.
    public var millis: Int64? {
        guard let separatorIndex = rawValue.firstIndex(of: Self.separator) else { return nil }
        return Int64(rawValue[rawValue.startIndex..<separatorIndex])
    }

    public var date: Date? {
        millis.map { Date(millisecondsSinceEpoch: $0) }
    }

    /// The identifier component, or `nil` for a sentinel.
    public var id: String? {
        guard let separatorIndex = rawValue.firstIndex(of: Self.separator) else { return nil }
        return String(rawValue[rawValue.index(after: separatorIndex)...])
    }

    // MARK: - Conformances

    public static func < (lhs: SortKey, rhs: SortKey) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var description: String { rawValue }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// MARK: - Date bridging

public extension Date {

    /// Public because the provider modules build `SortKey`s from server timestamps and need the
    /// same rounding behaviour, so this conversion must not be duplicated per provider.
    var millisecondsSinceEpoch: Int64 {
        // `rounded()` rather than truncation so a value converted to millis and back does not
        // drift downward, which would slowly walk a position marker backwards over many syncs.
        Int64((timeIntervalSince1970 * 1000).rounded())
    }

    init(millisecondsSinceEpoch millis: Int64) {
        self.init(timeIntervalSince1970: Double(millis) / 1000)
    }
}
