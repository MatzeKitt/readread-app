import Foundation
import ReadReadModel

// The JSON shape of each synced collection.
//
// Separate from the models so the wire format is explicit and versionable: a SwiftData model can be
// refactored freely, whereas these structures are a contract with every other device — including
// ones running an older build.

/// A single device's reading position in one scope.
public struct PositionPayload: Codable, Sendable, Equatable {

    public var scope: String
    public var deviceID: String
    public var markSortKey: String

    /// When the writing device last moved this position.
    ///
    /// Part of the contract, not a diagnostic. A position moves in both directions, so its value
    /// says nothing about which of two records is newer — only this does.
    public var updatedAt: Date

    public init(scope: String, deviceID: String, markSortKey: String, updatedAt: Date) {
        self.scope = scope
        self.deviceID = deviceID
        self.markSortKey = markSortKey
        self.updatedAt = updatedAt
    }

    /// The record id. Matches `PositionMark.key`, so a record maps to exactly one row.
    public var recordID: String { "\(scope)|\(deviceID)" }

    /// Whether this record should replace a stored one written at `otherUpdatedAt`.
    ///
    /// Compared on time rather than on position, which is the whole point of the model: a device
    /// that scrolls back down is reporting a genuinely earlier position, and that report must win
    /// if it is the more recent one. Comparing positions instead would make the count monotonic
    /// again, so it could never rise.
    ///
    /// Records only ever meet the row for their own device, so this is a same-device ordering: it
    /// exists to discard a record that arrives out of order, not to arbitrate between devices —
    /// that is `EffectivePosition.reduce`.
    public func supersedes(updatedAt otherUpdatedAt: Date) -> Bool {
        updatedAt > otherUpdatedAt
    }
}

/// A saved-for-later item, self-contained so it survives cache pruning on every device.
public struct ReadLaterPayload: Codable, Sendable, Equatable {

    public var itemID: String
    public var sourceID: String
    public var accountID: String
    public var kind: String
    public var title: String
    public var sourceTitle: String
    public var authorName: String?
    public var urlString: String?
    public var excerpt: String
    public var iconURLString: String?
    public var publishedAt: Date
    public var sortKey: String
    public var addedAt: Date

    /// Deliberately **not** synced.
    ///
    /// An offline snapshot can be hundreds of kilobytes of HTML per entry, which would dwarf
    /// everything else on the endpoint. Each device archives locally if it wants to.
    public var archivedHTML: String? { nil }
}

/// A user-defined ignore rule.
public struct FilterPayload: Codable, Sendable, Equatable {

    public var id: String
    public var name: String
    public var pattern: String
    public var fields: Int
    public var matchKind: String
    public var isCaseSensitive: Bool
    public var scope: FilterScope
    public var isEnabled: Bool
    public var createdAt: Date
    public var updatedAt: Date
}

/// A configured account — **never** its credentials.
///
/// The point of syncing this at all is that a new device shows the right servers and only needs
/// the passwords. Because no secret is in here, a compromised sync endpoint cannot read the user's
/// feeds or act as them on Mastodon.
public struct AccountPayload: Codable, Sendable, Equatable {

    public var id: String
    public var kind: String
    public var displayName: String
    public var serverURLString: String
    public var username: String
    public var createdAt: Date
    public var isEnabled: Bool
}

/// Encoding for sync payloads.
public enum SyncPayloadCoding {

    /// ISO 8601 with fractional seconds, so a date survives a round trip between devices without
    /// drifting a second each way.
    ///
    /// Built from `Date.ISO8601FormatStyle`, which is a `Sendable` value type — the
    /// `ISO8601DateFormatter` class cannot be held in a `static` under strict concurrency.
    private static let dateStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let dateStyleWithoutFraction = Date.ISO8601FormatStyle()

    /// `sortedKeys` so the same record always encodes to the same bytes. That makes an unchanged
    /// record byte-identical on re-encode, which is what lets the outbox recognise a no-op write
    /// and skip pushing it.
    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(dateStyle.format(date))
        }
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        // Accepts both spellings. The pair here is symmetric, but a payload written by a different
        // build of the app must still decode rather than failing the whole sync.
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            if let date = try? dateStyle.parse(raw) { return date }
            if let date = try? dateStyleWithoutFraction.parse(raw) { return date }
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Unparseable date '\(raw)'")
            )
        }
        return decoder
    }

    public static func encodeToString(_ value: some Encodable) throws -> String {
        String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    public static func decode<Value: Decodable>(_ type: Value.Type, from payload: String) throws -> Value {
        guard let data = payload.data(using: .utf8) else {
            throw SyncError.unexpectedResponse("Payload was not valid UTF-8")
        }
        return try decoder.decode(Value.self, from: data)
    }
}

// MARK: - Model bridging

public extension PositionPayload {

    init(_ mark: PositionMark) {
        self.init(
            scope: mark.scopeRaw,
            deviceID: mark.deviceID,
            markSortKey: mark.markSortKeyRaw,
            updatedAt: mark.updatedAt
        )
    }
}

public extension ReadLaterPayload {

    init(_ entry: ReadLaterEntry) {
        itemID = entry.itemID
        sourceID = entry.sourceID
        accountID = entry.accountID.uuidString
        kind = entry.kindRaw
        title = entry.title
        sourceTitle = entry.sourceTitle
        authorName = entry.authorName
        urlString = entry.urlString
        excerpt = entry.excerpt
        iconURLString = entry.iconURLString
        publishedAt = entry.publishedAt
        sortKey = entry.sortKeyRaw
        addedAt = entry.addedAt
    }
}

public extension FilterPayload {

    init(_ rule: FilterRule) {
        id = rule.id.uuidString
        name = rule.name
        pattern = rule.pattern
        fields = rule.fieldsRaw
        matchKind = rule.matchKindRaw
        isCaseSensitive = rule.isCaseSensitive
        scope = rule.scope
        isEnabled = rule.isEnabled
        createdAt = rule.createdAt
        updatedAt = rule.updatedAt
    }
}

public extension AccountPayload {

    init(_ account: AccountRecord) {
        id = account.id.uuidString
        kind = account.kindRaw
        displayName = account.displayName
        serverURLString = account.serverURLString
        username = account.username
        createdAt = account.createdAt
        isEnabled = account.isEnabled
    }
}
