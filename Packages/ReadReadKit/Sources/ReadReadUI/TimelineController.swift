import Foundation
import Observation
import ReadReadModel
import ReadReadSupport
import ReadReadSync
import SwiftData

/// Where the fold is on screen: which row is at the top of the viewport, and how far its top sits
/// from the viewport's top edge.
///
/// The offset is zero or negative — the fold row is the one *intruding* into the top edge, so its
/// top is at or above it. It is kept so that an anchored update can put the row back at exactly the
/// same pixel, not merely at the same row.
struct FoldReading: Equatable {
    var row: Int
    var offset: CGFloat
}

/// What the timeline controller needs from the platform list.
///
/// Implemented once per platform — `UICollectionView` on iOS, `NSTableView` on macOS — because
/// both have to do things SwiftUI's `List` cannot: report exactly what is at the fold, replace their
/// rows and put a given row at a given pixel in the same layout pass, and tell the reader's
/// scrolling apart from everything else.
///
/// The contract every implementation keeps:
///
/// - While the reader is not scrolling, the list holds the last placement — the row and offset it
///   was given or the reader left it at — against everything that changes its layout: rows sizing
///   themselves, images arriving, the window being resized. Nothing but the reader and the
///   controller moves it.
/// - The list stays invisible until its first placement has been laid out, so the top of the list
///   is never shown before the position is.
@MainActor
protocol TimelineSurface: AnyObject {

    /// Whether the list currently has a size to lay rows out in.
    var hasViewport: Bool { get }

    /// Replaces the rows and places `placement`, without animation, in one layout pass.
    func show(_ snapshot: TimelineSnapshot, placing placement: FoldReading?)

    /// Puts a row at the fold, without animation.
    func place(_ placement: FoldReading)

    /// Scrolls the least distance that brings `row` fully into view.
    func scrollRowToVisible(_ row: Int)

    /// What is at the fold now, or `nil` with no rows or no size.
    func foldReading() -> FoldReading?

    /// The rows on screen now, fold included.
    func visibleRows() -> Range<Int>?

    /// Redraws the rows on screen, for a change in what they show rather than in which rows there are.
    func reconfigureVisibleRows()

    /// Forgets anything measured for these items, whose contents changed in the store.
    func invalidate(itemIDs: Set<String>)

    /// Swaps the given rows for blanks of the same height, for items deleted from the store while
    /// their snapshot is still on screen. Removing the rows would move the list; the blanks go when
    /// the next snapshot is applied.
    func blank(rows: [Int])
}

/// Owns everything a timeline knows about where the reader is.
///
/// ## The algorithm
///
/// 1. **The rows are a frozen snapshot.** Store saves only build the next one in the background
///    (``TimelineSnapshotBuilder``); it waits in ``staged`` until the viewport is quiet.
/// 2. **One owner decides who moves the list** (``ViewportGate``). Nothing programmatic happens
///    while the reader scrolls, or for half a second after.
/// 3. **New rows are applied anchored** (``AnchorResolver``): the fold item keeps its exact pixel,
///    so arrivals appear above it and nothing on screen moves.
/// 4. **Only the reader's own settles are written**, stamped with when they settled
///    (``PositionWritePolicy``). Restoring, adopting and applying never write.
/// 5. **Another device's position is adopted** on activation, on opening the scope, or after the
///    list has been left alone for ten seconds — never during interaction, and never by writing.
@MainActor
@Observable
final class TimelineController {

    /// How long a store save is given to be followed by others before a snapshot is built.
    private static let rebuildDelay = Duration.milliseconds(300)

    /// How long a settle has to stand before it is written.
    ///
    /// Short, because writing is cheap once it only happens on settles: there is no scroll to
    /// debounce here, only a reader who may pick the list up again a moment later.
    private static let writeDelay = Duration.seconds(1)

    let scope: ScopeID

    /// The row at the fold, which is also how many items are above it.
    ///
    /// The one value observed while scrolling, and only by the small views that draw the count.
    /// The list itself never reads it.
    private(set) var foldRow: Int?

    /// Whether the rows on screen are none at all, for the empty-state overlay.
    private(set) var isEmpty = false

    /// Whether the first snapshot has been shown.
    private(set) var hasLoaded = false

    /// The rows the list is showing.
    @ObservationIgnored private(set) var snapshot = TimelineSnapshot.empty

    /// The next rows, built and waiting for a quiet moment.
    @ObservationIgnored private var staged: TimelineSnapshot?

    @ObservationIgnored private var gate = ViewportGate()

    @ObservationIgnored weak var surface: (any TimelineSurface)?

    /// Called once the scope has been placed at its position, with the item at the fold.
    @ObservationIgnored var didRestore: ((String) -> Void)?

    @ObservationIgnored private let services: AppServices
    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let counts: ThresholdCounts
    @ObservationIgnored private let builder: TimelineSnapshotBuilder
    @ObservationIgnored private let saves = NotificationRegistration()

    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var isDirty = false
    @ObservationIgnored private var isBuilding = false

    @ObservationIgnored private var rebuildTask: Task<Void, Never>?
    @ObservationIgnored private var quietTask: Task<Void, Never>?
    @ObservationIgnored private var writeTask: Task<Void, Never>?
    @ObservationIgnored private var adoptionTask: Task<Void, Never>?

    /// The reader's last settle that has not been written yet. What the flush on the way out sends.
    @ObservationIgnored private var pendingSettle: PositionWritePolicy.Settle?

    /// When the reader last came to rest here, written or not.
    @ObservationIgnored private var lastLocalSettle: Date?

    /// The last report from another device that was acted on, so none is applied twice.
    @ObservationIgnored private var lastAdopted: EffectivePosition?

    /// What may adopt another device's position at the next quiet moment.
    @ObservationIgnored private var pendingTrigger = PositionWritePolicy.AdoptionTrigger.idle

    init(scope: ScopeID, services: AppServices, context: ModelContext, counts: ThresholdCounts) {
        self.scope = scope
        self.services = services
        self.context = context
        self.counts = counts
        builder = TimelineSnapshotBuilder(modelContainer: services.container)
    }

    // MARK: - Lifecycle

    /// Connects the platform list and opens the scope. Called once, when the list is created.
    func attach(_ surface: any TimelineSurface) {
        self.surface = surface
        gate.hasViewport = surface.hasViewport
        guard !hasStarted else { return }
        hasStarted = true

        saves.observeSaves { [weak self] change in
            self?.storeDidSave(change)
        }
        Task { await open() }
    }

    /// The list is going away: write what the reader settled on, and stop.
    func detach() {
        flush()
        counts.clearLiveCount(for: scope)
        rebuildTask?.cancel()
        quietTask?.cancel()
        writeTask?.cancel()
        adoptionTask?.cancel()
    }

    /// Opens the scope at its position.
    ///
    /// Does not wait for this session to hear from the other devices first. The list opens where
    /// this store says the reader is, and moves once — while still untouched — if the merge says
    /// otherwise. Waiting would mean an empty column for up to the merge timeout on every launch.
    private func open() async {
        guard let built = await buildSnapshot() else { return }
        snapshot = built
        isEmpty = built.isEmpty

        let effective = try? ThresholdService.effectivePosition(for: scope, in: context)
        let placement = restorePlacement(in: built, effective: effective)
        if let effective, effective.deviceID != DeviceIdentity.current.id {
            // Placed there already, so it is not a report still to act on.
            lastAdopted = effective
        }

        ScrollDiagnostics.shared.event("open \(scope.rawValue): \(built.count) rows, fold row \(placement?.row ?? -1)")
        // The surface reveals itself once this placement is laid out, and reports back — see
        // `surfaceDidReveal()`, where the gate opens.
        surface?.show(built, placing: placement)
        setFold(placement?.row)
        hasLoaded = true

        if let row = placement?.row, built.rows.indices.contains(row) {
            didRestore?(built.rows[row].id)
        }

        if isDirty { scheduleRebuild() }

        await services.waitForPositionMerge()
        pendingTrigger = .open
        afterMerge()
    }

    /// The app, or this window, became active after being away.
    func activated() {
        Task {
            await services.waitForPositionMerge()
            pendingTrigger = .activation
            afterMerge()
        }
    }

    /// This session has heard the other devices: follow one that is ahead, then write what the
    /// reader did here meanwhile.
    ///
    /// In that order, because adopting a newer position drops an older pending settle, and a
    /// settle newer than what arrived is left for the write. Writing a settle that turns out older
    /// would be harmless anyway — it carries the time it was made (W2), so it loses the reduction —
    /// but there is no reason to push it.
    private func afterMerge() {
        evaluateAdoption()
        Task { await writePending() }
    }

    func setAppActive(_ isActive: Bool) {
        gate.isAppActive = isActive
        if isActive { scheduleQuietWork() }
    }

    // MARK: - Surface callbacks

    func surfaceDidChangeViewport(hasSize: Bool) {
        gate.hasViewport = hasSize
        if hasSize { scheduleQuietWork() }
    }

    /// The first placement is on screen.
    func surfaceDidReveal() {
        gate.positioned(at: .now)
        scheduleQuietWork()
    }

    func surfaceUserBegan() {
        gate.userBegan()
        // A settle that was waiting is still the reader's, and still flushed on the way out; it
        // just is not worth writing on a timer while the reader is moving on from it.
        writeTask?.cancel()
        // Coming back to the device no longer gives leave to move the list: the reader has
        // started reading here.
        pendingTrigger = .idle
    }

    /// The fold may have moved during the reader's scroll. Only the count follows it live.
    func surfaceFoldMoved() {
        guard gate.mayReadFold, let reading = surface?.foldReading() else { return }
        setFold(reading.row)
    }

    func surfaceUserEnded() {
        let mayRecord = gate.userEnded(at: .now)
        defer { scheduleQuietWork() }
        guard mayRecord else { return }
        recordSettle()
    }

    // MARK: - Reader commands

    /// Moves to a row because the reader asked to — a menu command, the keyboard. Recorded like a
    /// scroll, because it is one.
    func jump(to row: Int) {
        guard snapshot.rows.indices.contains(row), let surface else { return }
        gate.userBegan()
        surface.place(FoldReading(row: row, offset: 0))
        surfaceUserEnded()
    }

    /// Brings a row into view because the reader moved the selection to it with the keyboard.
    func reveal(row: Int) {
        guard snapshot.rows.indices.contains(row), let surface else { return }
        gate.userBegan()
        surface.scrollRowToVisible(row)
        surfaceUserEnded()
    }

    /// Goes back to the stored position — usually another device's — without claiming it.
    func returnToStoredPosition() {
        guard let surface, !snapshot.isEmpty else { return }
        let effective = try? ThresholdService.effectivePosition(for: scope, in: context)
        guard let placement = restorePlacement(in: snapshot, effective: effective) else { return }
        // The reader asked, so the gate's quiet period does not apply; but it is still not a
        // report, so it goes through the programmatic phase and writes nothing.
        guard gate.beginRequested() else { return }
        surface.place(placement)
        gate.endProgrammatic()
        setFold(placement.row)
        if let effective { lastAdopted = effective }
    }

    // MARK: - Rows

    func row(of itemID: String?) -> Int? {
        itemID.flatMap { snapshot.row(of: $0) }
    }

    func itemID(at row: Int) -> String? {
        snapshot.rows.indices.contains(row) ? snapshot.rows[row].id : nil
    }

    func item(at row: Int) -> CachedItem? {
        itemID(at: row).flatMap(item(withID:))
    }

    /// An item, fetched by id so one that has since been deleted comes back `nil` instead of
    /// faulting a model that no longer exists. The snapshot on screen can outlive its items.
    func item(withID id: String) -> CachedItem? {
        var descriptor = FetchDescriptor<CachedItem>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    // MARK: - Snapshots

    private func storeDidSave(_ change: StoreChange) {
        if !change.deleted.isEmpty {
            let rows = snapshot.rows.indices.filter { change.deleted.contains(snapshot.rows[$0].persistentID) }
            if !rows.isEmpty { surface?.blank(rows: rows) }
        }
        if !change.updated.isEmpty {
            let ids = snapshot.rows.lazy.filter { change.updated.contains($0.persistentID) }.map(\.id)
            if !ids.isEmpty { surface?.invalidate(itemIDs: Set(ids)) }
        }
        scheduleRebuild()
        // A pull may have brought another device's position in.
        evaluateAdoption()
    }

    private func scheduleRebuild() {
        isDirty = true
        guard hasLoaded else { return }
        rebuildTask?.cancel()
        rebuildTask = Task { [weak self] in
            try? await Task.sleep(for: Self.rebuildDelay)
            guard !Task.isCancelled, let self else { return }
            await rebuild()
        }
    }

    private func rebuild() async {
        guard !isBuilding else { return }
        isBuilding = true
        isDirty = false
        let built = await buildSnapshot()
        isBuilding = false

        if let built {
            staged = built
            applyStagedIfQuiet()
        }
        // Saved again while building: the snapshot may already be behind.
        if isDirty { scheduleRebuild() }
    }

    private func buildSnapshot() async -> TimelineSnapshot? {
        generation += 1
        return try? await builder.build(scope: scope, generation: generation)
    }

    /// Replaces the rows on screen with the staged ones, keeping the fold item at its pixel.
    private func applyStagedIfQuiet() {
        guard let next = staged, let surface else { return }

        if next.hasSameRows(as: snapshot) {
            staged = nil
            snapshot = next
            return
        }

        guard gate.beginProgrammatic(at: .now) else {
            scheduleQuietWork()
            return
        }
        defer { gate.endProgrammatic() }

        let placement: FoldReading?
        if snapshot.isEmpty {
            // Nothing was on screen to keep: this is the scope being opened late, so it opens at
            // its position.
            let effective = try? ThresholdService.effectivePosition(for: scope, in: context)
            placement = restorePlacement(in: next, effective: effective)
        } else {
            let reading = surface.foldReading() ?? foldRow.map { FoldReading(row: $0, offset: 0) }
            if let reading, snapshot.rows.indices.contains(reading.row),
               let resolution = AnchorResolver.resolve(anchor: snapshot.rows[reading.row], old: snapshot, new: next) {
                placement = FoldReading(row: resolution.row, offset: resolution.isSameItem ? reading.offset : 0)
            } else {
                placement = nil
            }
        }

        ScrollDiagnostics.shared.event(
            "apply \(snapshot.count) → \(next.count) rows, fold row \(foldRow ?? -1) → \(placement?.row ?? -1)"
        )
        staged = nil
        snapshot = next
        isEmpty = next.isEmpty
        surface.show(next, placing: placement)
        setFold(placement?.row)
    }

    // MARK: - Quiet work

    /// Runs what was waiting for the reader to leave the list alone: a staged snapshot, then a
    /// position from another device.
    private func scheduleQuietWork() {
        quietTask?.cancel()
        quietTask = Task { [weak self] in
            try? await Task.sleep(for: ViewportGate.quietDelay + .milliseconds(20))
            guard !Task.isCancelled, let self else { return }
            guard gate.isQuiet(at: .now) else { return }
            applyStagedIfQuiet()
            evaluateAdoption()
        }
    }

    // MARK: - Writing

    private func recordSettle() {
        guard let reading = surface?.foldReading(), snapshot.rows.indices.contains(reading.row) else { return }
        setFold(reading.row)

        let row = snapshot.rows[reading.row]
        let settle = PositionWritePolicy.Settle(itemID: row.id, sortKey: row.sortKey, at: .now)
        lastLocalSettle = settle.at
        pendingSettle = settle
        ScrollDiagnostics.shared.event("settle at row \(reading.row) (\(row.id))")

        clearSeenLateArrivals()

        writeTask?.cancel()
        writeTask = Task { [weak self] in
            try? await Task.sleep(for: Self.writeDelay)
            guard !Task.isCancelled, let self else { return }
            await writePending()
        }
    }

    private func shouldWrite(_ settle: PositionWritePolicy.Settle) -> Bool {
        let stored: EffectivePosition? = (try? ThresholdService.effectivePosition(for: scope, in: context)).map {
            var localised = $0
            localised.markSortKey = (try? ThresholdService.localisedMark($0.markSortKey, in: context)) ?? $0.markSortKey
            return localised
        }
        return PositionWritePolicy.shouldWrite(.init(
            settle: settle,
            stored: stored,
            arePositionsMerged: services.arePositionsMerged,
            deviceID: DeviceIdentity.current.id
        ))
    }

    private func writePending() async {
        guard let settle = pendingSettle else { return }
        guard shouldWrite(settle) else {
            if services.arePositionsMerged { pendingSettle = nil }
            return
        }
        let wrote = await services.commitPosition(scope: scope, itemID: settle.itemID, settledAt: settle.at)
        if wrote, pendingSettle == settle { pendingSettle = nil }
    }

    /// Writes the reader's last settle now, on the main context, for when the list or the app is
    /// going away.
    ///
    /// Sends an existing claim with its own time — see W2 in ``PositionWritePolicy``. The one new
    /// claim it makes is for a reader caught mid-scroll, whose fold is no less theirs for not
    /// having come to rest.
    func flush() {
        writeTask?.cancel()
        if gate.phase == .interacting, gate.hasViewport {
            recordSettle()
            writeTask?.cancel()
        }
        guard let settle = pendingSettle, shouldWrite(settle) else { return }

        guard
            let wrote = try? PositionCommit.write(
                scope: scope,
                itemID: settle.itemID,
                deviceID: DeviceIdentity.current.id,
                updatedAt: settle.at,
                in: context
            ),
            wrote
        else { return }

        pendingSettle = nil
        try? context.save()
        services.positionSettled()
    }

    // MARK: - Adoption

    private func evaluateAdoption() {
        guard hasLoaded, let surface, !snapshot.isEmpty else { return }
        guard let effective = try? ThresholdService.effectivePosition(for: scope, in: context) else { return }

        let local = (try? ThresholdService.localisedMark(effective.markSortKey, in: context)) ?? effective.markSortKey
        var targetRow: Int?
        if let row = snapshot.foldRow(for: local), snapshot.rows[row].sortKey == local {
            targetRow = row
        }

        let now = ContinuousClock.now
        let decision = PositionWritePolicy.adoption(.init(
            stored: effective,
            deviceID: DeviceIdentity.current.id,
            targetRow: targetRow,
            foldRow: foldRow,
            lastLocalSettle: lastLocalSettle,
            lastAdopted: lastAdopted,
            trigger: pendingTrigger,
            isQuiet: gate.isQuiet(at: now),
            timeLeftAlone: gate.timeLeftAlone(at: now)
        ))

        switch decision {
        case .settled:
            adoptionTask?.cancel()
            lastAdopted = effective
            pendingTrigger = .idle

        case .notNow:
            // Only worth asking again on a timer when the article is here and it is the reader's
            // quiet that is missing. An article still to arrive brings its own snapshot, and every
            // apply asks again.
            guard targetRow != nil else { return }
            adoptionTask?.cancel()
            adoptionTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self?.evaluateAdoption()
            }

        case .scroll(let row):
            guard gate.beginProgrammatic(at: now) else { return }
            ScrollDiagnostics.shared.event("adopt \(effective.deviceID ?? "?") → row \(row)")
            surface.place(FoldReading(row: row, offset: 0))
            gate.endProgrammatic()
            setFold(row)
            lastAdopted = effective
            pendingTrigger = .idle
            adoptionTask?.cancel()
            // Older than the report just followed — the policy only adopts reports newer than the
            // reader's last settle here.
            pendingSettle = nil
        }
    }

    // MARK: - Helpers

    /// Where a snapshot opens for a stored position.
    ///
    /// At the top for a scope nobody has a position in, as it always has: the count already says
    /// everything is new, and the bottom of a week of history is not where anybody wants to start.
    private func restorePlacement(in snapshot: TimelineSnapshot, effective: EffectivePosition?) -> FoldReading? {
        guard !snapshot.isEmpty else { return nil }
        guard let effective, effective.markSortKey != .distantPast else {
            return FoldReading(row: 0, offset: 0)
        }
        let mark = (try? ThresholdService.localisedMark(effective.markSortKey, in: context)) ?? effective.markSortKey
        return snapshot.foldRow(for: mark).map { FoldReading(row: $0, offset: 0) }
    }

    private func setFold(_ row: Int?) {
        guard row != foldRow else { return }
        foldRow = row
        counts.reportLiveCount(row, for: scope)
    }

    /// Takes the older-item mark off everything the reader can see: an item on screen has not been
    /// missed. Not in Older Items itself, where the mark *is* the list.
    private func clearSeenLateArrivals() {
        if case .lateArrivals = scope { return }
        guard let rows = surface?.visibleRows() else { return }
        var changed = false
        for row in rows {
            guard let item = item(at: row), item.arrivedLate else { continue }
            item.arrivedLate = false
            changed = true
        }
        if changed { try? context.save() }
    }
}

/// What a store save changed, as far as an open timeline cares.
struct StoreChange: Sendable {
    var deleted: Set<PersistentIdentifier>
    var updated: Set<PersistentIdentifier>
}

extension NotificationRegistration {

    /// Registers for every store save, delivered on the main actor with what the save deleted and
    /// updated.
    func observeSaves(handler: @escaping @MainActor (StoreChange) -> Void) {
        observe(ModelContext.didSave, extract: { notification in
            func ids(_ key: ModelContext.NotificationKey) -> Set<PersistentIdentifier> {
                Set(notification.userInfo?[key.rawValue] as? [PersistentIdentifier] ?? [])
            }
            return StoreChange(deleted: ids(.deletedIdentifiers), updated: ids(.updatedIdentifiers))
        }, handler: handler)
    }
}
