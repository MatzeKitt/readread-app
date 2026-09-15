import Foundation
import SwiftData

/// Where an account's ingest walk has reached.
///
/// ## The two-cursor scheme
///
/// Ingest pages newest-first and stops at the first already-known item. That needs two separate
/// bookmarks, and conflating them is the bug this type exists to prevent:
///
/// - `highestSeenID` is the **stop line** for the descending walk. It is promoted to the run's
///   maximum *only when the whole run completes.*
/// - `resumeContinuation` is **where the current walk left off**, persisted after every page.
///
/// If `highestSeenID` advanced page by page, an interrupted run would raise the stop line to the
/// newest item it had seen while the older pages it never fetched still sat below it. The next run
/// would stop immediately at the new line, and everything in that gap would be skipped
/// permanently — silently, with no error and no way to notice.
@Model
public final class SyncCursor {

    /// `"<accountID>|<streamKey>"`, since a Mastodon account and a FreshRSS account walk different
    /// streams and each account may later gain more than one.
    #Unique<SyncCursor>([\.key])
    public var key: String = ""

    public var accountID: UUID = UUID()

    /// Which stream this cursor tracks, e.g. `reading-list` or `home`.
    public var streamKey: String = ""

    /// Provider id of the newest item confirmed ingested by a **completed** run. Empty means
    /// nothing has been ingested yet, so the first walk runs to its page budget and stops.
    ///
    /// For FreshRSS this is the decimal entry id, which is a microsecond timestamp and therefore
    /// monotonic with insertion. For Mastodon it is the status snowflake id.
    public var highestSeenID: String = ""

    /// The provider's continuation token for resuming the descending walk, or empty when no walk
    /// is in progress.
    public var resumeContinuation: String = ""

    /// Set while a run is walking. Distinguishes "no walk in progress" from "walk in progress that
    /// happens to start at the newest item".
    public var isWalkInProgress: Bool = false

    /// Highest provider id observed during the walk currently in progress. This is what gets
    /// promoted into `highestSeenID` on completion.
    public var pendingHighestSeenID: String = ""

    /// The history window this cursor's stop line was established under, in days (`0` = no bound).
    ///
    /// Recorded because widening the window is otherwise a setting that only works one way. The
    /// walk stops at the first id it already knows, and ids are insertion-ordered — so an article
    /// published *and* inserted five weeks ago sits below the stop line forever. Going from one
    /// week to one month would appear to do nothing at all.
    ///
    /// Comparing this against the current setting is what lets a changed window discard the stop
    /// line for one run and walk the stream again.
    public var historyWindowDays: Int = 0

    public var lastCompletedRunAt: Date?

    /// When the id-reconciliation pass last ran. That pass is what notices server-side deletions,
    /// which a purely additive descending walk can never see.
    public var lastReconciledAt: Date?

    public init(accountID: UUID, streamKey: String) {
        key = Self.key(accountID: accountID, streamKey: streamKey)
        self.accountID = accountID
        self.streamKey = streamKey
    }

    public static func key(accountID: UUID, streamKey: String) -> String {
        "\(accountID.uuidString)|\(streamKey)"
    }
}
