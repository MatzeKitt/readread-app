import Foundation

/// A FreshRSS entry id, normalised across the two spellings the API uses.
///
/// ## Why this type exists
///
/// The Google Reader API returns the *same* entry id in two incompatible forms:
///
/// - `stream/contents` → `"tag:google.com,2005:reader/item/0005f2a1b3c4d5e6"` — a long tag URI
///   ending in **zero-padded 16-digit hex**.
/// - `stream/items/ids` → `"1685459810234342"` — a bare **64-bit decimal**, and the same form the
///   `continuation` cursor uses.
///
/// Treating those as different keys is the classic Google Reader client bug: the descending walk
/// stores hex ids, the reconciliation pass compares decimal ids, nothing matches, and every item is
/// re-inserted as new on every sync. Funnelling both through one type makes that mistake impossible
/// to make by accident.
///
/// The canonical form here is the **unsigned 64-bit value**, because that is what the hex spells
/// literally and it round-trips both directions without loss.
public struct GReaderItemID: Hashable, Sendable, Comparable, CustomStringConvertible {

    /// Prefix on the long form. Historic and fixed — the year is part of the literal.
    static let tagPrefix = "tag:google.com,2005:reader/item/"

    public let value: UInt64

    public init(value: UInt64) {
        self.value = value
    }

    // MARK: - Parsing

    /// Parses either spelling.
    ///
    /// Accepts the tag URI, a bare hex string, or a decimal string — so a caller never has to know
    /// which endpoint a given id came from.
    public init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let body = trimmed.range(of: Self.tagPrefix, options: [.anchored, .caseInsensitive]) {
            // Everything after the tag prefix is hex by definition of the format.
            guard let parsed = UInt64(trimmed[body.upperBound...], radix: 16) else { return nil }
            value = parsed
            return
        }

        // A bare decimal is the `items/ids` and `continuation` form. Try it first: every decimal
        // string is also valid hex, so testing hex first would silently misread `"10"` as 16.
        if let decimal = UInt64(trimmed, radix: 10) {
            value = decimal
            return
        }

        // Google Reader itself emitted *signed* decimal for ids past `Int64.max`, with the hex
        // being the two's-complement. FreshRSS only ever produces positive ids, but honouring the
        // signed form costs nothing and keeps this usable against a real Reader-compatible server.
        if let signed = Int64(trimmed, radix: 10) {
            value = UInt64(bitPattern: signed)
            return
        }

        if let hex = UInt64(trimmed, radix: 16) {
            value = hex
            return
        }

        return nil
    }

    // MARK: - Rendering

    /// Zero-padded 16-digit lowercase hex, as `stream/contents` spells it.
    public var hexString: String {
        String(format: "%016llx", value)
    }

    /// Bare decimal, as `stream/items/ids` and `continuation` spell it.
    public var decimalString: String {
        String(value)
    }

    /// The full tag URI.
    public var tagURI: String {
        Self.tagPrefix + hexString
    }

    /// The form used to build `CachedItem.id`.
    ///
    /// Hex rather than decimal purely so ids are a fixed width and therefore sort and read
    /// consistently in logs and the store; the choice is arbitrary but must stay stable, because
    /// changing it would orphan every cached item and Read Later entry.
    public var storageString: String { hexString }

    public var description: String { decimalString }

    public static func < (lhs: GReaderItemID, rhs: GReaderItemID) -> Bool {
        lhs.value < rhs.value
    }
}

extension GReaderItemID: Codable {

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let parsed = GReaderItemID(raw) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Unparseable entry id '\(raw)'")
            )
        }
        self = parsed
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(decimalString)
    }
}
