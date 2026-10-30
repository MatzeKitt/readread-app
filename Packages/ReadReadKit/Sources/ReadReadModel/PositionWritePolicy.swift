import Foundation

/// When a timeline writes its own reading position, and when it moves to another device's.
///
/// ## The invariants
///
/// Positions are reduced by *most recently written* (``EffectivePosition/reduce(_:scope:)``), so a
/// written row is a claim that the reader was there at that moment. Every write that is not such a
/// claim corrupts every device. Hence:
///
/// - **W1** Only the reader moving the list writes a position. Restoring, adopting, applying a
///   snapshot, launching and quitting never do.
/// - **W2** A position is stamped with when the reader came to rest there, not with when it
///   happened to be saved or pushed. Flushing on the way out sends an existing claim; it does not
///   make a new one.
/// - **W3** Adopting another device's position writes nothing, so two devices cannot keep handing
///   the same position back and forth with ever fresher timestamps.
///
/// W1 and W3 are enforced by the caller only ever asking ``shouldWrite(_:)`` with a fold the
/// reader settled on — see ``ViewportGate/userEnded(at:)`` — and W2 by the settle carrying its own
/// timestamp.
public enum PositionWritePolicy {

    /// A fold the reader came to rest on.
    public struct Settle: Equatable, Sendable {

        public var itemID: String
        public var sortKey: SortKey

        /// When the reader stopped. Becomes the row's `updatedAt` — see W2.
        public var at: Date

        public init(itemID: String, sortKey: SortKey, at: Date) {
            self.itemID = itemID
            self.sortKey = sortKey
            self.at = at
        }
    }

    public struct WriteContext: Sendable {

        /// The settle being considered.
        public var settle: Settle

        /// The effective position across every device, already localised to this store.
        public var stored: EffectivePosition?

        /// Whether this session has heard the other devices' positions yet.
        ///
        /// Until it has, a scroll is a move away from a place this device may have been wrong
        /// about, and writing it would outrank the device the reader was actually using.
        public var arePositionsMerged: Bool

        /// This device's id.
        public var deviceID: String

        public init(settle: Settle, stored: EffectivePosition?, arePositionsMerged: Bool, deviceID: String) {
            self.settle = settle
            self.stored = stored
            self.arePositionsMerged = arePositionsMerged
            self.deviceID = deviceID
        }
    }

    public static func shouldWrite(_ context: WriteContext) -> Bool {
        guard context.arePositionsMerged else { return false }

        // Already the position, and this device's own: nothing to say. A position that is the
        // same item but another device's is still worth writing — the reader is here now, and
        // writing it is what lets this device's later moves win.
        if let stored = context.stored,
           stored.markSortKey == context.settle.sortKey,
           stored.deviceID == context.deviceID {
            return false
        }
        return true
    }

    // MARK: - Adoption

    /// What gives a device leave to move an open list to another device's position.
    public enum AdoptionTrigger: Equatable, Sendable {

        /// The app or its window became active: the reader has just come back to this device.
        case activation

        /// The scope was opened.
        case open

        /// Nothing happened; the list has simply been left alone for a while.
        case idle
    }

    /// How long a list has to be left alone before another device's position may move it without
    /// the reader having just come back to it.
    public static let idleAdoptionDelay = Duration.seconds(10)

    public struct AdoptionContext: Sendable {

        /// The effective position, already localised to this store.
        public var stored: EffectivePosition

        public var deviceID: String

        /// The row the stored position puts at the fold in the snapshot on screen, if it can be
        /// placed exactly — `nil` when the item it names is not in the snapshot yet.
        public var targetRow: Int?

        /// The row at the fold now.
        public var foldRow: Int?

        /// When the reader last came to rest in this scope on this device, written or not.
        ///
        /// A report older than that is older than what the reader just did here, whatever the
        /// stored rows say: the local write may simply not have landed yet.
        public var lastLocalSettle: Date?

        /// The report most recently adopted, so one is never applied twice.
        public var lastAdopted: EffectivePosition?

        public var trigger: AdoptionTrigger

        /// Whether the viewport may be touched at all. See ``ViewportGate/isQuiet(at:)``.
        public var isQuiet: Bool

        /// How long the reader has left the list alone. See ``ViewportGate/timeLeftAlone(at:)``.
        public var timeLeftAlone: Duration?

        public init(
            stored: EffectivePosition,
            deviceID: String,
            targetRow: Int?,
            foldRow: Int?,
            lastLocalSettle: Date?,
            lastAdopted: EffectivePosition?,
            trigger: AdoptionTrigger,
            isQuiet: Bool,
            timeLeftAlone: Duration?
        ) {
            self.stored = stored
            self.deviceID = deviceID
            self.targetRow = targetRow
            self.foldRow = foldRow
            self.lastLocalSettle = lastLocalSettle
            self.lastAdopted = lastAdopted
            self.trigger = trigger
            self.isQuiet = isQuiet
            self.timeLeftAlone = timeLeftAlone
        }
    }

    public enum AdoptionDecision: Equatable, Sendable {

        /// Move the list to this row.
        case scroll(row: Int)

        /// Nothing to do now, and nothing to remember: ask again later.
        case notNow

        /// The list is already there, or the report is not one to follow. Remember it as handled.
        case settled
    }

    public static func adoption(_ context: AdoptionContext) -> AdoptionDecision {
        let stored = context.stored

        // This device's own position, or nobody's.
        guard let writer = stored.deviceID, writer != context.deviceID else { return .settled }
        guard stored.markSortKey != .distantPast else { return .settled }

        if let lastAdopted = context.lastAdopted, lastAdopted == stored { return .settled }

        // Older than what the reader just did here.
        if let lastLocalSettle = context.lastLocalSettle, stored.updatedAt <= lastLocalSettle {
            return .settled
        }

        // The article the report names has not arrived yet. Not remembered, so it is applied once
        // the snapshot that brings the article in has been shown.
        guard let targetRow = context.targetRow else { return .notNow }

        if targetRow == context.foldRow { return .settled }

        guard context.isQuiet else { return .notNow }

        switch context.trigger {
        case .activation, .open:
            return .scroll(row: targetRow)
        case .idle:
            guard let alone = context.timeLeftAlone, alone >= idleAdoptionDelay else { return .notNow }
            return .scroll(row: targetRow)
        }
    }
}
