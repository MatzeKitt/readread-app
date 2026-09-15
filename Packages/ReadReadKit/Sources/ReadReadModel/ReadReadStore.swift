import Foundation
import SwiftData

/// Creates the app's SwiftData container.
///
/// There is exactly one store and it is entirely local. Sync happens over the self-hosted HTTP
/// endpoint instead of CloudKit mirroring, which is why the models here are free to use
/// `#Unique` constraints and non-optional attributes — restrictions CloudKit mirroring would
/// otherwise impose on the whole schema.
public enum ReadReadStore {

    /// Every model in the store. Cache models and synced models live together because they are
    /// queried together (a timeline row needs its item, its source and its position), and a single
    /// store keeps those reads in one transaction.
    public static let schema = Schema([
        CachedItem.self,
        CachedSource.self,
        SyncCursor.self,
        PositionMark.self,
        ReadLaterEntry.self,
        FilterRule.self,
        AccountRecord.self,
        PendingChange.self,
        SyncState.self,
    ])

    /// The on-disk container used by the app.
    public static func container(url: URL? = nil) throws -> ModelContainer {
        let configuration = if let url {
            ModelConfiguration(schema: schema, url: url)
        } else {
            ModelConfiguration(schema: schema)
        }
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    /// An ephemeral container for tests and previews.
    public static func inMemoryContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
