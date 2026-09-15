import Foundation
import ReadReadModel

/// An in-memory `IngestSink` that behaves like the real store for cursor purposes and records
/// everything, so tests can assert on both the final item set and the sequence of commits.
public actor RecordingIngestSink: IngestSink {

    public struct Commit: Sendable, Equatable {
        public var itemIDs: [String]
        public var resumeContinuation: String
        public var pendingHighestSeenID: String
    }

    /// Cursor rows, keyed the way `SyncCursor` keys them.
    private var cursors: [String: IngestCursorState] = [:]

    /// Every item ever committed, in insertion order, deduplicated by id like the store's
    /// `#Unique` constraint does.
    public private(set) var items: [String: IngestedItem] = [:]
    public private(set) var insertionOrder: [String] = []

    public private(set) var commits: [Commit] = []
    public private(set) var completions: [String] = []
    public private(set) var abandonments = 0
    public private(set) var sources: [IngestedSource] = []

    public init(initialState: IngestCursorState = .fresh, accountID: UUID? = nil, streamKey: String = "reading-list") {
        if let accountID {
            cursors[Self.key(accountID, streamKey)] = initialState
        }
    }

    private static func key(_ accountID: UUID, _ streamKey: String) -> String {
        "\(accountID.uuidString)|\(streamKey)"
    }

    // MARK: - Inspection

    public var itemCount: Int { items.count }

    public var committedIDs: [String] { insertionOrder }

    public func state(accountID: UUID, streamKey: String = "reading-list") -> IngestCursorState {
        cursors[Self.key(accountID, streamKey)] ?? .fresh
    }

    /// Simulates the process being killed mid-run: committed work and cursors survive, in-memory
    /// run state does not — exactly what a real crash or an expired background task leaves behind.
    public func clearRecordings() {
        commits.removeAll()
        completions.removeAll()
        abandonments = 0
    }

    // MARK: - IngestSink

    public func cursorState(accountID: UUID, streamKey: String) async throws -> IngestCursorState {
        cursors[Self.key(accountID, streamKey)] ?? .fresh
    }

    @discardableResult
    public func commit(
        items newItems: [IngestedItem],
        accountID: UUID,
        streamKey: String,
        resumeContinuation: String,
        pendingHighestSeenID: String
    ) async throws -> Int {
        for item in newItems where items[item.id] == nil {
            insertionOrder.append(item.id)
        }
        for item in newItems {
            items[item.id] = item
        }

        var state = cursors[Self.key(accountID, streamKey)] ?? .fresh
        state.resumeContinuation = resumeContinuation
        state.pendingHighestSeenID = pendingHighestSeenID
        // A walk is in progress from the first commit onwards; only completion clears it.
        state.isWalkInProgress = true
        cursors[Self.key(accountID, streamKey)] = state

        commits.append(Commit(
            itemIDs: newItems.map(\.id),
            resumeContinuation: resumeContinuation,
            pendingHighestSeenID: pendingHighestSeenID
        ))
        return 0
    }

    public func completeRun(
        accountID: UUID,
        streamKey: String,
        highestSeenID: String,
        historyWindowDays: Int
    ) async throws {
        var state = cursors[Self.key(accountID, streamKey)] ?? .fresh
        state.highestSeenID = highestSeenID
        state.historyWindowDays = historyWindowDays
        state.resumeContinuation = ""
        state.pendingHighestSeenID = ""
        state.isWalkInProgress = false
        cursors[Self.key(accountID, streamKey)] = state
        completions.append(highestSeenID)
    }

    public func abandonRun(accountID: UUID, streamKey: String) async throws {
        // Deliberately leaves `highestSeenID` and the resume cursor exactly as they are.
        abandonments += 1
    }

    public func upsertSources(_ newSources: [IngestedSource], accountID: UUID) async throws {
        sources = newSources
    }
}
