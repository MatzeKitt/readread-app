import Foundation
import ReadReadModel

/// A record as the sync endpoint stores it.
///
/// `payload` stays a `String` all the way through rather than being decoded here. The server treats
/// it as opaque, and so does this layer: each collection knows how to read its own payload, which
/// is what lets a new field be added to one record type without touching the transport.
public struct SyncRecord: Sendable, Equatable {

    public var collection: SyncCollection
    public var id: String
    public var revision: Int
    public var deleted: Bool

    /// Server clock, milliseconds. Used for last-writer-wins on the collections that need it —
    /// never for positions, which cannot conflict.
    public var updatedAt: Int

    /// Opaque JSON, empty for a tombstone.
    public var payload: String

    public init(
        collection: SyncCollection,
        id: String,
        revision: Int,
        deleted: Bool,
        updatedAt: Int,
        payload: String
    ) {
        self.collection = collection
        self.id = id
        self.revision = revision
        self.deleted = deleted
        self.updatedAt = updatedAt
        self.payload = payload
    }
}

extension SyncRecord: Decodable {

    private enum CodingKeys: String, CodingKey {
        case collection, id, revision, deleted, updatedAt, payload
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawCollection = try container.decode(String.self, forKey: .collection)

        guard let collection = SyncCollection(rawValue: rawCollection) else {
            throw SyncError.unknownCollection(rawCollection)
        }
        self.collection = collection
        id = try container.decode(String.self, forKey: .id)
        revision = try container.decode(Int.self, forKey: .revision)
        deleted = try container.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
        updatedAt = try container.decodeIfPresent(Int.self, forKey: .updatedAt) ?? 0
        payload = try container.decodeIfPresent(String.self, forKey: .payload) ?? ""
    }
}

/// One page of `GET /api/v1/changes`.
public struct SyncChangesPage: Decodable, Sendable {

    public var records: [SyncRecord]

    /// The cursor to store once this page has been applied.
    ///
    /// This is the page's own highest revision, not the server's global maximum — storing the
    /// global maximum after a partial page would skip every remaining page.
    public var maxRevision: Int

    public var hasMore: Bool

    public init(records: [SyncRecord], maxRevision: Int, hasMore: Bool) {
        self.records = records
        self.maxRevision = maxRevision
        self.hasMore = hasMore
    }
}

/// A record being pushed. Carries no revision — the server assigns that.
public struct SyncPushRecord: Encodable, Sendable, Equatable {

    public var collection: SyncCollection
    public var id: String
    public var deleted: Bool
    public var payload: String

    public init(collection: SyncCollection, id: String, deleted: Bool = false, payload: String) {
        self.collection = collection
        self.id = id
        self.deleted = deleted
        self.payload = payload
    }

    private enum CodingKeys: String, CodingKey {
        case collection, id, deleted, payload
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(collection.rawValue, forKey: .collection)
        try container.encode(id, forKey: .id)
        try container.encode(deleted, forKey: .deleted)
        try container.encode(payload, forKey: .payload)
    }
}

/// Result of `POST /api/v1/changes`.
public struct SyncPushResult: Decodable, Sendable {

    public struct Applied: Decodable, Sendable {
        public var collection: String
        public var id: String
        public var revision: Int
    }

    public var applied: [Applied]

    /// The highest revision after this push.
    ///
    /// **Deliberately not usable as a pull cursor.** Another device may have written a lower
    /// revision this client has not pulled yet, so adopting this value would skip it permanently.
    /// The pull cursor only ever advances from a pull.
    public var maxRevision: Int
}

/// Response of `GET /api/v1/health`.
public struct SyncHealth: Decodable, Sendable {
    public var ok: Bool
    public var service: String?
    public var version: String?
    public var schemaVersion: Int?
}

public enum SyncError: Error, Sendable, Equatable {

    /// No server URL or token has been configured yet.
    case notConfigured

    /// The bearer token was rejected. Tokens do not expire, so this means revoked or mistyped.
    case unauthorized

    case invalidServerURL(String)

    /// The server sent a collection this build does not know. Newer server, older app.
    case unknownCollection(String)

    /// The response was not the expected JSON, which usually means the URL points at something
    /// other than the sync service.
    case unexpectedResponse(String)

    /// The server refused a record. Carries its message, which names the offending field.
    case rejected(String)
}
