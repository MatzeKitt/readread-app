import Foundation
import SwiftData

/// Which synced collection a record belongs to.
///
/// The sync endpoint treats payloads as opaque JSON, so this enum is the *client's* interpretation
/// of what a record is. Adding a collection therefore needs no server change.
public enum SyncCollection: String, Hashable, Sendable, Codable, CaseIterable {
    case position
    case readLater
    case filter
    case account
}

/// A local change waiting to be pushed to the sync endpoint.
///
/// An explicit outbox rather than "diff the store against the server on each sync". Two reasons:
/// a change made offline must survive relaunch and still push later, and diffing cannot tell a
/// local deletion from a record that simply has not been pulled yet — so tombstones would
/// resurrect.
@Model
public final class PendingChange {

    /// `"<collection>|<recordID>"`. One row per record: a second edit to the same record replaces
    /// the queued payload rather than queueing behind it, since only the final state matters.
    #Unique<PendingChange>([\.key])
    public var key: String = ""

    /// `SyncCollection.rawValue`.
    public var collectionRaw: String = SyncCollection.position.rawValue

    public var recordID: String = ""

    /// The record's JSON payload, or empty for a deletion.
    public var payload: Data = Data()

    /// Deletions push as tombstones so other devices learn about them.
    public var isDeletion: Bool = false

    public var queuedAt: Date = Date.now

    /// Consecutive push failures, used to back off rather than retry a permanently-rejected record
    /// on every sync.
    public var failureCount: Int = 0

    public init(collection: SyncCollection, recordID: String, payload: Data, isDeletion: Bool = false) {
        key = Self.key(collection: collection, recordID: recordID)
        collectionRaw = collection.rawValue
        self.recordID = recordID
        self.payload = payload
        self.isDeletion = isDeletion
        queuedAt = .now
    }

    public static func key(collection: SyncCollection, recordID: String) -> String {
        "\(collection.rawValue)|\(recordID)"
    }

    public var collection: SyncCollection {
        get { SyncCollection(rawValue: collectionRaw) ?? .position }
        set { collectionRaw = newValue.rawValue }
    }
}
