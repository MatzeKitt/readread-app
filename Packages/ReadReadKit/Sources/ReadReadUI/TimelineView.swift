import Combine
import ReadReadModel
import ReadReadSupport
import ReadReadSync
import SwiftData
import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// What the debounced position write is keyed on.
private struct CommitKey: Equatable {
    var isReady: Bool
    var foldItemID: String?

    /// Part of the key so that the gate opening re-runs the commit.
    ///
    /// Without it, a reader who scrolled while this device had not yet heard from the others would
    /// have that fold refused once and never reconsidered — the fold has not changed since, so
    /// nothing else would ever ask again, and the position would go unrecorded until the next
    /// scroll. See ``PositionPublication``.
    var arePositionsMerged: Bool
}

/// Where the reader currently is in a scope's list.
///
/// A reference type on purpose. See ``TimelineList/fold`` for why this is not `@State`.
@MainActor
@Observable
final class FoldState {

    /// The item at the fold — the row intruding into the top of the viewport.
    ///
    /// Held as an **id**, not a row index, because a row index is invalidated the moment items are
    /// inserted above it: auto-refresh keeps the same row under the reader, so index 5 becomes a
    /// different item while the fold has not actually moved.
    ///
    /// Settable only through ``move(to:row:in:)``, so it cannot be moved without saying which list
    /// it was read from. See ``scope``.
    private(set) var itemID: String?

    /// How many items sit above the fold, straight from the table.
    ///
    /// The row index *is* the count: the rows above the fold are exactly indices `0..<row`.
    ///
    /// Writable on its own, unlike ``itemID``, because arrivals re-index the fold without moving
    /// it: the same item sits at a larger row and the count above it has to follow. That is not a
    /// move, and it cannot change which list the fold belongs to.
    var row: Int?

    /// Which list this fold was read from.
    ///
    /// Recorded because a fold is only meaningful in the list it was measured in, and writing one
    /// down under another list's name silently rewrites a reading position that has no backup.
    /// That is not hypothetical — it is what a shared view instance did, and `TimelineView` carries
    /// the note about the identity that allowed it.
    ///
    /// Kept here rather than trusted to the view's lifetime on purpose. The view's lifetime *was*
    /// the assumption that failed, so the fold now carries its own answer and
    /// ``PositionPublication/shouldPublish(fold:stored:isRestoredFold:foldScope:writingScope:)``
    /// checks it. Belt and braces, and the braces are the testable half.
    private(set) var scope: ScopeID?

    /// Moves the fold, recording the list it was read from.
    ///
    /// The only way to move it. Two fields that must agree are set by one call rather than by
    /// whoever remembers to set both — which is the shape the bug above took, one field at a time
    /// across four call sites.
    func move(to itemID: String?, row: Int?, in scope: ScopeID) {
        self.itemID = itemID
        self.row = row
        self.scope = scope
    }

    /// Set when the fold was moved to match *another device's* position rather than by scrolling.
    ///
    /// The commit is keyed on the fold, so adopting a position would otherwise look exactly like
    /// the reader moving to it: this device would write the adopted row under its own id with a
    /// fresh timestamp, outrank the device it just agreed with, and that device would adopt it
    /// back. Two idle devices would trade the same position for ever, forty-nine records at a
    /// time. Marking the adopted fold lets the commit tell "I was told this" from "I did this".
    ///
    /// Cleared by ``readFold()``, so the first genuine scroll makes this device authoritative
    /// again — which is right, because by then the reader really has moved.
    var adoptedItemID: String?

    /// Set when the fold is where the *restore* put it, rather than where the reader did.
    ///
    /// The sibling of ``adoptedItemID`` and for the same reason, one step earlier: a restore
    /// reproduces a position this device already held, so it has nothing new to report. Publishing
    /// it anyway stamps a stale place with a fresh timestamp, and reduction takes the most recently
    /// written row — so opening a device that was behind made *its* backlog the truth everywhere.
    /// `SwiftDataIngestSink.maySeedPositions` documents the identical trap on the ingest side and
    /// guards against it; this is the path that did not.
    ///
    /// Not cleared by ``readFold()``, unlike the adopted one. It does not need to be: the test is
    /// whether the fold is *still* the item the restore chose, so the first scroll onto any other
    /// row makes it false on its own.
    var restoredItemID: String?

    /// The item visibly at the fold, and where it sits — recorded on **every** reading, including
    /// the ones the fold itself stands down for.
    ///
    /// ## Why this cannot be ``itemID``
    ///
    /// While an arrival is being held, ``readFold()`` deliberately stops updating the fold: the
    /// whole claim of a hold is that the reading position has *not* moved, and re-reading it from
    /// displaced geometry is what once made a refresh mark everything it had just fetched as read.
    ///
    /// That freeze is right for the position and wrong for an anchor. An anchor has one job — name
    /// what is on screen at this instant, so a correction puts it back exactly there — and a frozen
    /// one names where the reader *was*. So a second batch landing during a hold armed the pin with
    /// an offset from before the reader had scrolled, and the correction dragged them back to it.
    ///
    /// Two fields rather than one shared with the position, because they answer questions that
    /// genuinely differ while a hold is live, and every attempt to serve both from one of them made
    /// one of the two wrong.
    /// `@ObservationIgnored`, like the clock below, and for the same reason the whole of this type
    /// is a reference: these are written on every scroll callback, and an observed write would
    /// invalidate whoever read them — which for anything inside the list means re-running a query
    /// over a few thousand items in the middle of a scroll. Nobody draws from them.
    @ObservationIgnored var anchorItemID: String?

    /// How far the anchor's top sits below the top edge of the viewport.
    ///
    /// The other half of the same reading: ``ScrollAnchor`` puts the row back *here* rather than
    /// against the edge, and pinning it to the edge instead is what used to make the position creep
    /// a row per refresh.
    @ObservationIgnored var anchorOffset: CGFloat = 0

    /// When the list last reported that it moved.
    ///
    /// The debounce's actual input. Keying the commit on the *fold* alone was not enough: the fold
    /// changes when a row crosses the top edge, so scrolling slowly through one tall post holds it
    /// still for longer than the debounce and the write landed mid-gesture. This is the question
    /// worth asking — has the scrolling stopped — rather than a proxy for it.
    @ObservationIgnored var lastScrollAt: ContinuousClock.Instant?
}

/// When a fold held against the top edge may be read from the screen again.
///
/// Its own type, and not because it is long. This is the rule that stands between an auto-refresh
/// and the reading position, it cannot be exercised through the view — deciding it needs a laid-out
/// table on screen — and getting it wrong destroys data that has no backup: there is no read/unread
/// state in this app, so a position overwritten with "the newest item" cannot be reconstructed from
/// anything. See ``TimelineList/isHoldReleased()`` for the reasoning; this is the arithmetic.
enum FoldHold {

    /// - Parameters:
    ///   - liveRow: what the screen currently reports as the fold, or `nil` when the table cannot
    ///     say — during a relayout, or before it has rows.
    ///   - heldRow: where the held item now sits in the list, or `nil` when it has left the scope.
    static func isReleased(liveRow: Int?, heldRow: Int?) -> Bool {
        // Nothing left to hold: the item is gone from the list, so the screen is the only source
        // of truth there is.
        guard let heldRow else { return true }

        // No reading to judge by. Holding is the safe answer — the alternative is trusting a
        // number that does not exist yet.
        guard let liveRow else { return false }

        // At or below the held row: either the pin landed, or the reader has scrolled on past it.
        // Above it is the ambiguous case — an insertion produces exactly that, and so does
        // scrolling up into what just arrived — and the honest reading of both is that the fold
        // has not moved.
        return liveRow >= heldRow
    }

    /// The same question, with the two answers geometry alone cannot give.
    ///
    /// ## The freeze that had no way out
    ///
    /// The rule above resolves its one ambiguous case — the fold appearing to move *up* — by
    /// holding. That is right for an insertion and wrong for a reader, and nothing distinguished
    /// them, so a reader scrolling up was simply not believed. Which is exactly what someone does
    /// after the app has been away for a while: the new items are at the top, so they scroll up
    /// into them, the fold never comes back down to the held row, and the hold never lifts.
    ///
    /// A hold that never lifts freezes the fold, and the fold is both the count beside the list and
    /// the reading position. So the counts stopped moving, and opening an item wrote the position
    /// the app had been *restored* to rather than the one on screen — reported as coming back to
    /// where the session started.
    ///
    /// - Parameters:
    ///   - readerIsScrolling: Whether the reader has hold of the list. This answers the ambiguity
    ///     outright rather than guessing at it: an insertion does not touch the scroller, so a fold
    ///     that moved while the reader was scrolling moved because they moved it.
    ///   - heldFor: How long the hold has been in place, or `nil` when that is not known.
    ///   - limit: How long a hold may last at most. A backstop, not the mechanism — a frozen
    ///     reading position is a worse failure than a fold read a moment too early, so no hold gets
    ///     to outlive its insertion by more than this however the evidence reads.
    static func isReleased(
        liveRow: Int?,
        heldRow: Int?,
        readerIsScrolling: Bool,
        heldFor: Duration?,
        limit: Duration
    ) -> Bool {
        if readerIsScrolling { return true }
        if let heldFor, heldFor >= limit { return true }
        return isReleased(liveRow: liveRow, heldRow: heldRow)
    }
}

/// How much longer a fold has to hold still before it counts as settled.
///
/// Its own type for the same reason ``FoldHold`` is: it decides when a reading position is written,
/// getting it wrong loses one, and it cannot be exercised through the view. It is also the thing
/// that was wrong the first time — see ``TimelineList/commitPosition()``.
enum PositionDebounce {

    /// - Parameters:
    ///   - elapsed: How long ago the list last reported that it moved, or `nil` when it never has.
    ///   - delay: How much quiet is required.
    /// - Returns: How much longer to wait. `.zero` means the fold has settled and may be written.
    static func remainingQuiet(sinceLastScroll elapsed: Duration?, delay: Duration) -> Duration {
        // Never scrolled, so there is no scroll to wait out. The restore's own settling is what
        // produced this fold, and it is as settled as it will ever be.
        guard let elapsed else { return .zero }
        return elapsed >= delay ? .zero : delay - elapsed
    }
}

/// Whether a settled fold is worth writing down as this device's reading position.
///
/// Its own type for the same reason ``FoldHold`` and ``PositionDebounce`` are: it decides whether a
/// reading position is published to every other device, getting it wrong corrupts the one piece of
/// state this app has no way to reconstruct, and it cannot be exercised through the view.
///
/// Both rules exist because a position is written per device and reduced by *most recently
/// written*. That rule is sound for reader actions and wrong for everything else, so the job here
/// is to let only reader actions through.
enum PositionPublication {

    /// - Parameters:
    ///   - fold: The key the list is sitting on now.
    ///   - stored: The effective position across every device, already localised to this store, or
    ///     `nil` when it could not be read. Unreadable counts as "do not publish": writing a
    ///     position without knowing what it replaces is how one gets lost.
    ///   - isRestoredFold: Whether this fold is the one the restore put there, untouched since.
    ///   - foldScope: The list the fold was measured in, or `nil` when it has never been read.
    ///   - writingScope: The list whose position is about to be written.
    ///   - arePositionsMerged: Whether this session has pulled the other devices' positions yet.
    static func shouldPublish(
        fold: SortKey,
        stored: SortKey?,
        isRestoredFold: Bool,
        foldScope: ScopeID?,
        writingScope: ScopeID,
        arePositionsMerged: Bool
    ) -> Bool {
        // Nothing may be claimed before this device knows what it is claiming against.
        //
        // The other rules here all describe a position the app *derived* — restored, adopted,
        // seeded — and refuse to let it masquerade as a report. This one is about the reader, and
        // it is the case none of the others covered: a scroll is a genuine report, but a scroll
        // away from a *stale restore* is a report about a place the reader was put by a store that
        // had not yet heard from the device they were actually reading on. Published, it wins the
        // reduction on its timestamp and the other device adopts it back.
        //
        // Deliberately the first check, before even the scope test: until the gate opens there is
        // no question worth asking. `AppServices.arePositionsMerged` bounds the wait, so this
        // suppresses a report for seconds at most, and `TimelineFoldSink` re-runs the commit when
        // it opens — so the fold the reader established meanwhile is written then rather than lost.
        guard arePositionsMerged else { return false }

        // A fold measured in one list and about to be written down as another list's position.
        //
        // First, because it is the only one of these rules that is not about *whether* the reader
        // moved but about *where* — and a position taken from the wrong list is not a slightly
        // wrong position, it is a place the reader has never been in that scope. Scrolling through
        // Older Items and returning to All Items used to move All Items there, because the two
        // shared a view and therefore a fold; `TimelineView` carries the note on the identity that
        // fixed it, and this is what keeps it fixed if that identity is ever lost again.
        //
        // `nil` — a fold never read — is not this scope either, and has nothing to say regardless.
        guard foldScope == writingScope else { return false }

        guard let stored else { return false }

        // A restore reproduces what was already stored. Even when it lands a hair off — a pruned
        // item, a row measured short — what it has to say is "this is where I was", which is the
        // thing already on record. Publishing re-dates it, and a re-dated stale position outranks
        // a device that is genuinely further ahead.
        guard !isRestoredFold else { return false }

        // Nothing stored anywhere. Seeding a scope's first position belongs to ingest, which waits
        // for the first sync pull before doing it precisely so a device cannot claim to be caught
        // up before it has heard from the others — see `SwiftDataIngestSink.maySeedPositions`. A
        // list that has simply not been told yet must not claim it either.
        //
        // Reached only by a fold the reader moved, since a restored one has already returned above.
        guard stored != .distantPast else { return false }

        // Unchanged, so there is nothing to say. The write is not free: it restamps this scope and
        // every scope it cascades into, and queues a sync record for each.
        return fold != stored
    }
}

/// Which of a list's items a row range reported by the backing view actually names.
///
/// Its own type because the arithmetic is where this goes wrong and the consequence is silent: the
/// range comes from a table that has its own idea of how many rows it holds, and the array it is
/// being applied to is the one SwiftUI is about to hand it. When they disagree — mid-insertion,
/// mid-prune — an unclamped range either traps or names the wrong items, and here that would take
/// the older-item mark off articles the reader has never seen.
enum VisibleRows {

    /// The reported range, narrowed to the rows that exist.
    ///
    /// `nil` when nothing was reported, when the list is empty, or when the range lies entirely
    /// past the end — all three meaning "nothing on screen to act on", which is the answer the
    /// caller wants in each case.
    static func clamped(_ rows: ClosedRange<Int>?, count: Int) -> ClosedRange<Int>? {
        guard let rows, count > 0 else { return nil }
        let first = max(rows.lowerBound, 0)
        let last = min(rows.upperBound, count - 1)
        guard first <= last else { return nil }
        return first...last
    }
}

/// The window subtitle and the debounced position write, both of which follow the fold.
///
/// Its own view so that reading the fold takes a dependency *here* rather than in the list. Held
/// as a background of the list, which keeps it in the hierarchy — `navigationSubtitle` travels up
/// as a preference, so it does not matter that this draws nothing.
private struct TimelineFoldSink: View {

    let fold: FoldState
    let scope: ScopeID
    let counts: ThresholdCounts
    let isReady: Bool
    let commit: @MainActor () async -> Void

    /// Read *here* rather than by the list, which is the whole reason this view exists. The gate
    /// changes once or twice a session, but taking the dependency in the list's body would drag
    /// the timeline through a rebuild for it — the same reasoning as the fold itself.
    @Environment(AppServices.self) private var services

    var body: some View {
        Color.clear
            // `.task(id:)` *is* the debounce: a new fold cancels the pending sleep, so the write
            // happens once the scroll settles rather than once per row that crosses the top edge.
            //
            // Keyed on readiness as well as the fold. The restore's own scrolling settles the fold
            // *before* it marks itself finished, so keying on the fold alone meant the task had
            // already run and bailed by then, and never ran again — the position was never written
            // at all until the reader happened to scroll.
            .task(id: CommitKey(
                isReady: isReady,
                foldItemID: fold.itemID,
                arePositionsMerged: services.arePositionsMerged
            )) {
                await commit()
            }
            // Both platforms: this was macOS-only because `navigationSubtitle` used to be, and
            // iPhone was left with no count anywhere except the sidebar it had already navigated
            // away from — in an app whose whole premise is that number.
            .navigationSubtitle(subtitle)
    }

    private var subtitle: Text {
        // Read from the live fold in both cases. Older Items used to take the stored count here
        // while every other scope took the fold, so its subtitle alone did not follow scrolling.
        let count = fold.row ?? counts.newerCount(for: scope)

        if case .lateArrivals = scope {
            // Not "newer": these arrived below the position of the scope they landed in, and
            // calling them newer is the exact confusion the separate list exists to avoid.
            return count == 0
                ? Text("Nothing waiting")
                : Text("^[\(count) item](inflect: true) arrived")
        }
        return count == 0 ? Text("Up to date") : Text("\(count) newer")
    }
}

/// A position another device reported, in both the form it was written in and the form this store
/// can act on.
///
/// Two fields rather than one because they answer different questions, and collapsing them into the
/// translated key alone is what made the list jump. See ``ForeignPosition/reported``.
private struct ForeignPosition: Equatable {

    /// The key the other device actually wrote.
    ///
    /// The identity of the *report*, and the only part of this that is stable: it does not change
    /// when this store's contents change. So it is what says whether a position has already been
    /// acted on, and one already acted on is never applied twice however often the value below
    /// moves.
    var reported: SortKey

    /// The same position, translated into this store's key space by
    /// `ThresholdService.localisedMark(_:in:)`.
    ///
    /// A **store lookup**, so it changes as items arrive and are pruned: before this device has
    /// the article the mark names, the mark comes back untranslated; once ingest brings the article
    /// in, the same mark starts resolving to the local row's key. That change is the signal that a
    /// position which could not be placed before can be placed now — which is why it is watched —
    /// and it is emphatically not the signal that another device reported something new.
    var local: SortKey

    /// Whether this store actually holds the row ``local`` names.
    ///
    /// Not implied by the translation succeeding: a mark that could not be translated comes back
    /// unchanged, which is indistinguishable from one that needed no translation. See
    /// `ThresholdService.holdsItem(at:for:in:)`.
    var isPlaceable: Bool
}

/// What to do with a position another device reported.
///
/// Its own type for the same reason as ``PositionPublication``: the rule cannot be exercised
/// through the view — deciding it needs a laid-out list and a second device — and getting it wrong
/// is not visible in a diff. This is the half that can be tested.
enum PositionAdoption {

    enum Decision: Equatable {

        /// Move the list there, and remember the report so it is not applied a second time.
        case scroll

        /// The list is already where the report wants it. Remember it; scroll nothing.
        case recordOnly

        /// The report names an article this store does not have yet. Do nothing, and **do not
        /// remember it**, so it is applied when ingest brings the article in.
        case waitForItems

        /// Already applied.
        case ignore
    }

    /// - Parameters:
    ///   - isAlreadyAdopted: Whether this exact report — as the other device wrote it — has been
    ///     applied before.
    ///   - isPlaceable: Whether the article the report names is in this store.
    ///   - isFoldAtReport: Whether the fold is already sitting on the reported position.
    static func decide(
        isAlreadyAdopted: Bool,
        isPlaceable: Bool,
        isFoldAtReport: Bool
    ) -> Decision {
        // First, and on the *reported* key rather than the translated one. A report is applied
        // once however often this store's answer about it moves, which is what stopped an ordinary
        // refresh from scrolling the list out from under a reader who had moved on.
        if isAlreadyAdopted { return .ignore }

        // The case the whole retry exists for, and the one it used to miss.
        //
        // `itemAtPosition` finds the item at the marker by *offset*, so it answers for any
        // non-empty scope — including when the marker is a key this store cannot place, which is
        // exactly what a position arriving ahead of its article is. Acting on that put the reader
        // at a row chosen by how two devices' account ids happened to sort, and recording it made
        // the wrong answer permanent: when the article finally arrived and the mark became
        // placeable, the report was refused as already applied.
        //
        // Waiting is the honest answer. The count still reflects the report meanwhile; only the
        // scroll is deferred, and `ForeignPosition.local` changing is what brings it back.
        guard isPlaceable else { return .waitForItems }

        return isFoldAtReport ? .recordOnly : .scroll
    }
}

/// Watches this scope's stored positions and reports one written by another device.
///
/// ## Why the open list has to be told
///
/// Sync moved the rows all along — a server log showed both devices pushing and pulling positions
/// every half minute — and it still looked completely broken, because nothing downstream acted on
/// them. `restorePosition` runs when the view appears and never again, so a position arriving from
/// the other device changed the *count* while the list stayed exactly where it was. Then the local
/// fold was re-read on the next scroll and overwrote the incoming position with the one still on
/// screen. Two devices, faithfully exchanging positions, each ignoring the other's.
///
/// A `@Query` of its own rather than a value passed down from the host: position rows are the one
/// thing that must be observed *here*, and there are two of them per scope, so this costs nothing
/// — unlike the item query, which is deliberately kept out of this view.
private struct TimelinePositionWatcher: View {

    let scope: ScopeID

    /// How many items the list is showing, so this re-evaluates when ingest lands more.
    ///
    /// Not used in the body — its job is to be a dependency. A report that arrived ahead of its
    /// article is deliberately left unrecorded so it can be applied when the article turns up, and
    /// noticing that it has turned up means recomputing `isPlaceable`. The `@Query` below watches
    /// *positions*, so on its own nothing here would re-run when items arrive.
    ///
    /// That used to be carried by the translation changing, which is a store lookup — but once
    /// account ids are derived rather than minted, a foreign mark needs no translation, so `local`
    /// reads the same before and after the article lands and the old signal goes quiet. This one
    /// does not depend on the ids differing.
    let itemCount: Int

    let adopt: @MainActor (ForeignPosition) async -> Void

    @Environment(\.modelContext) private var modelContext

    @Query private var marks: [PositionMark]

    init(
        scope: ScopeID,
        itemCount: Int,
        adopt: @escaping @MainActor (ForeignPosition) async -> Void
    ) {
        self.scope = scope
        self.itemCount = itemCount
        self.adopt = adopt
        let raw = scope.rawValue
        _marks = Query(filter: #Predicate<PositionMark> { $0.scopeRaw == raw })
    }

    private var foreignPosition: ForeignPosition? {
        let effective = EffectivePosition.reduce(
            marks.map { (deviceID: $0.deviceID, markSortKey: $0.markSortKey, updatedAt: $0.updatedAt) },
            scope: scope
        )
        // Only a *foreign* winner is adopted. This device's own row is rewritten on every settled
        // scroll, so while someone is reading here their own row keeps winning and the list is
        // never yanked out from under them — which is the whole reason the test is on the device
        // rather than on the timestamp.
        guard let deviceID = effective.deviceID, deviceID != DeviceIdentity.current.id else {
            return nil
        }
        guard effective.markSortKey != .distantPast else { return nil }
        // Translated as well as reported, like every other reader of a position — see
        // `ThresholdService.localisedMark`. Without the translation the key handed to
        // `adoptRemotePosition` could never equal a local item's, so its "already where it wants
        // to be" early-out never fired and every arriving mark scrolled the list again. Carried
        // *beside* the reported key rather than in place of it, for the reason ``ForeignPosition``
        // gives.
        let local = (try? ThresholdService.localisedMark(effective.markSortKey, in: modelContext))
            ?? effective.markSortKey
        // Asked here, where the store is already being consulted, and carried on the report — so
        // the decision below is made from facts rather than from a fetch that answers for any
        // non-empty scope. See `PositionAdoption`.
        let isPlaceable = (try? ThresholdService.holdsItem(at: local, for: scope, in: modelContext)) ?? false
        return ForeignPosition(reported: effective.markSortKey, local: local, isPlaceable: isPlaceable)
    }

    var body: some View {
        Color.clear
            .task(id: foreignPosition) {
                guard let foreignPosition else { return }
                await adopt(foreignPosition)
            }
    }
}

/// The "N newer" button's face.
///
/// Split out for the same reason as ``TimelineFoldSink``: the count moves with every row that
/// crosses the fold, and reading it inside the list's own body would drag the whole list — and its
/// query — through a rebuild each time.
private struct TimelineCountLabel: View {

    let fold: FoldState
    let scope: ScopeID
    let counts: ThresholdCounts

    var body: some View {
        let newer = fold.row ?? counts.newerCount(for: scope)
        if newer == 0 {
            Label("Up to date", systemImage: "checkmark.circle")
        } else {
            // Built out rather than `Label(_:systemImage:)`, so the glyph can take the accent
            // colour on its own and leave the count set in the toolbar's own.
            Label {
                Text("\(newer) newer")
            } icon: {
                Image(systemName: "bell.badge")
            }
        }
    }
}

/// Refresh, as its own view rather than inline in the timeline's toolbar.
///
/// Not tidiness. It reads `isRefreshing`, which changes at the start and end of every refresh, and
/// an `@Observable` read inside `TimelineView.body` would take that dependency for the *routing*
/// view — whose child owns the timeline's `@Query`, and re-evaluating that re-runs a fetch over
/// the whole scope. Reading it one level down confines the update to the button that is changing,
/// which is the same reason `SidebarRowView` and `TimelineCountLabel` exist.
struct RefreshToolbarButton: View {

    @Environment(AppServices.self) private var services
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        #if os(macOS)
        button
            // Not while Reduce Motion is on. On the Mac this is the app's one piece of
            // *continuous decoration* — the arrow turns for as long as a refresh takes, which on a
            // slow network is a long time to keep something spinning at someone who has asked for
            // less movement. The button being disabled is what says a refresh is running; the spin
            // only ever dressed that up.
            .symbolEffect(.rotate, isActive: services.isRefreshing && !reduceMotion)
        #else
        // A spinner in place of the button, rather than an effect on it, because a symbol effect
        // does not survive the trip to a `UIBarButtonItem`: what crosses is the label's *image*,
        // not the view it was attached to. The same reason a `ProgressView` in the label's icon
        // slot showed nothing — there was no image in it to take. As the item's own content
        // SwiftUI has to host a real view, and the indicator renders.
        //
        // Swapping the whole item changes its identity, so it crossfades rather than morphing.
        // That is the intended reading here: the button is gone for as long as the work runs.
        //
        // Deliberately *not* gated on Reduce Motion, unlike the Mac's spin. This is not decoration
        // standing in for a disabled button — on a phone it is the only thing on screen saying the
        // app is working, and a progress indicator is the platform's own idiom for exactly that.
        if services.isRefreshing {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Refreshing")
        } else {
            button
        }
        #endif
    }

    private var button: some View {
        Button("Refresh", systemImage: "arrow.clockwise") {
            Task { await services.refreshNow() }
        }
        .keyboardShortcut("r", modifiers: .command)
        .disabled(services.isRefreshing)
        .toolbarButtonHelp("Refresh")
    }
}

/// The item list for the selected scope.
///
/// Ordered newest-published first, which is the ordering the whole threshold design is built
/// around: recently-fetched old content stays where it belongs chronologically rather than
/// floating to the top.
struct TimelineView: View {

    let scope: ScopeID
    @Binding var selectedItemID: String?
    let counts: ThresholdCounts
    /// Called to hand keyboard focus to another column.
    let moveFocus: (FocusedColumn) -> Void

    @Environment(\.modelContext) private var modelContext

    var body: some View {
        Group {
            if case .readLater = scope {
                // Read Later renders from `ReadLaterEntry`, not `CachedItem`, because entries are
                // self-contained snapshots that outlive cache pruning.
                ReadLaterListView(selectedItemID: $selectedItemID, moveFocus: moveFocus)
            } else if case .filtered = scope {
                // Its own view rather than the timeline with an inverted predicate: every row says
                // *which* rule hid it, which is the only question the list exists to answer, and
                // there is no reading position to restore or report here.
                FilteredItemsView(selectedItemID: $selectedItemID, moveFocus: moveFocus)
            } else {
                TimelineQueryHost(
                    scope: scope,
                    selectedItemID: $selectedItemID,
                    counts: counts,
                    moveFocus: moveFocus
                )
                // One list per scope, and this one modifier is what makes that true.
                //
                // Without it every timeline scope — All Items, a folder, a feed, Older Items —
                // is the *same* branch of the `Group` above, so SwiftUI matched them by position
                // and type and handed the new scope the old scope's view: its `@State`, its fold,
                // its `hasRestored`, and the table's own scroll offset. Read Later and Filtered
                // Items were unaffected, being branches of their own, which is why this looked
                // like it worked.
                //
                // What that cost: switching scope restored nothing, because `restorePosition` is
                // a `.task` on a view that never went away, and `hasRestored` was already true —
                // so the list simply stayed where the previous scope had left it. Then the fold
                // settled and was written down as the *new* scope's reading position. Scrolling
                // through Older Items and returning to All Items moved All Items to where Older
                // Items had been left, and there is no read/unread state here to recover a
                // position from.
                //
                // `TimelineQueryHost` already documents the intent — "a scope change has to
                // produce a new view instance" — and splitting the query out was necessary for
                // that but never sufficient. A different `@Query` predicate is not a different
                // identity.
                .id(scope)
            }
        }
        .navigationTitle(scopeTitle)
        // No `.toolbar` here, and that is the fix for a real bug rather than a tidying.
        //
        // Refresh used to be declared on this view — the column's root — so that one declaration
        // would serve all three lists below. It worked for the timeline and put the button in the
        // *reading pane's* end of the merged strip for Read Later, Older Items and Filtered Items:
        // the one action that belongs to the list, as far from the list as the window allows.
        //
        // The difference between the cases is this `Group`. Its branch changes identity when the
        // scope changes, and a toolbar attached above a branch that comes and goes is one SwiftUI
        // has to re-home; the lists that declared a toolbar of their own anchored theirs and this
        // one drifted. So every list now declares the whole of its own toolbar, Refresh included,
        // and none of them is nested under a second declaration that outlives them.
    }

    private var scopeTitle: String {
        switch scope {
        case .all: String(localized: "All Items")
        case .readLater: String(localized: "Read Later")
        case .lateArrivals: String(localized: "Older Items")
        case .filtered: String(localized: "Filtered Items")
        case .folder(let name): name
        case .mastodonHome: String(localized: "Home")
        case .source(let id): sourceTitle(for: id) ?? String(localized: "Feed")
        }
    }

    private func sourceTitle(for sourceID: String) -> String? {
        var descriptor = FetchDescriptor<CachedSource>(predicate: #Predicate { $0.id == sourceID })
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first?.title
    }
}

/// The list itself, split out so its `@Query` can be rebuilt when the scope changes.
///
/// `@Query` takes its predicate at initialisation, so a scope change has to produce a *new* view
/// instance. Keeping this separate from `TimelineView` is what lets the parent hold stable state
/// while the query underneath is replaced — and it also gives every scope its own scroll position
/// and its own fold tracking, which is what makes positions track per scope.
/// Owns the queries; owns no selection.
///
/// This split exists for one measured reason. `@Query` re-runs its fetch whenever the view holding
/// it re-evaluates, and a fetch over a few thousand items costs about a quarter of a second. The
/// list below owns `selection`, which `List` reads — so **every arrow-key press re-fetched the
/// entire timeline** before the article could be drawn. Profiled while arrowing through twenty
/// articles: `items.getter` was 2,481 of 5,335 samples, and that delay *was* the "opening an
/// article is slow" complaint.
///
/// Handing the results down as plain arrays fixes it without changing what is displayed: this view
/// re-evaluates when the store changes, which is exactly when a new fetch is warranted, and the
/// child re-evaluates on selection without dragging a query behind it.
private struct TimelineQueryHost: View {

    let scope: ScopeID
    @Binding var selectedItemID: String?
    let counts: ThresholdCounts
    let moveFocus: (FocusedColumn) -> Void

    @Query private var items: [CachedItem]

    /// Source titles for the row header line, resolved once for the whole list.
    ///
    /// A per-row fetch would issue a query for every cell SwiftUI realises while scrolling; there
    /// are only ever a handful of sources, so one query and a dictionary is strictly cheaper.
    @Query private var sources: [CachedSource]

    /// Everything currently saved for later.
    ///
    /// Queried whole and reduced to a set of ids rather than asking per row: the timeline realises
    /// rows as fast as it can scroll, and a `contains` query per cell is the classic way to make a
    /// list stutter. The list is small — what a person puts aside, not what they subscribe to.
    @Query private var readLaterEntries: [ReadLaterEntry]

    /// The accounts, for the Like and Boost menu.
    ///
    /// Here rather than in the row's menu for the same reason `sources` is here: a row is realised
    /// as fast as the list can scroll, and a `@Query` inside one is a fetch per cell. There are
    /// only ever a handful of accounts and they change when somebody signs in, which is not while
    /// scrolling.
    @Query private var accounts: [AccountRecord]

    init(
        scope: ScopeID,
        selectedItemID: Binding<String?>,
        counts: ThresholdCounts,
        moveFocus: @escaping (FocusedColumn) -> Void
    ) {
        self.scope = scope
        _selectedItemID = selectedItemID
        self.counts = counts
        self.moveFocus = moveFocus
        _items = Query(
            filter: ScopeQuery.displayPredicate(for: scope),
            sort: \CachedItem.sortKeyRaw,
            order: .reverse
        )
    }

    var body: some View {
        TimelineList(
            scope: scope,
            selectedItemID: $selectedItemID,
            counts: counts,
            moveFocus: moveFocus,
            items: items,
            sources: sources,
            readLaterEntries: readLaterEntries,
            accounts: accounts
        )
    }
}

private struct TimelineList: View {

    /// How long the scroll must settle before the position is written.
    ///
    /// Long enough that flicking through a scope does not queue a write and a sync push per row,
    /// short enough that closing the app right after reading keeps the position.
    private static let commitDelay = Duration.milliseconds(1_500)

    /// How long to let layout settle between restore attempts.
    private static let restoreSettleDelay = Duration.milliseconds(60)

    /// How long to let an arrival settle before deciding what is on screen.
    ///
    /// Comfortably longer than ``anchorHoldWindow``: within that window the hold is still moving
    /// the list, so the rows in front of the reader are not final yet, and the only cost of
    /// waiting is that an item stays marked as an older item for half a second longer.
    private static let arrivalSettleDelay = Duration.milliseconds(600)

    /// How long the fold is kept against its offset after items arrive above it.
    ///
    /// The correction itself is applied by the backing view's own geometry pass — see
    /// ``TimelineFoldReader/Handle/holdAnchor(row:offset:for:)`` — so this is not a schedule of
    /// attempts but a window in which corrections are still welcome. Long enough to cover a table
    /// that measures its row heights over several passes; short enough that a reader who starts
    /// scrolling the instant items land is not fighting it.
    private static let anchorHoldWindow: TimeInterval = 0.4

    /// How many times to ask the backing view to apply the hold, in case it never reports a
    /// geometry change of its own.
    ///
    /// Insurance, not the mechanism. A pin that is already correct is a subtraction and a
    /// comparison, so asking a few extra times costs nothing — and the alternative, if a platform
    /// declines to report its content size changing, is the twitch coming back with no clue why.
    private static let anchorHoldPasses = 3

    /// The longest a fold may be held still after items arrived above it.
    ///
    /// Comfortably longer than ``anchorHoldWindow`` and the retry passes together, because it is
    /// not how long the hold is *meant* to last — it is the point past which a hold has clearly
    /// failed to lift on evidence, and a frozen reading position is worse than an early reading.
    private static let foldHoldLimit = Duration.seconds(1)

    let scope: ScopeID
    @Binding var selectedItemID: String?
    let counts: ThresholdCounts
    let moveFocus: (FocusedColumn) -> Void

    /// Fetched by ``TimelineQueryHost``, which is the whole point — see its documentation.
    let items: [CachedItem]
    let sources: [CachedSource]
    let readLaterEntries: [ReadLaterEntry]
    let accounts: [AccountRecord]

    @Environment(\.modelContext) private var modelContext
    @Environment(SettingsModel.self) private var settings
    @Environment(AppServices.self) private var services
    @Environment(\.openURL) private var openURL

    /// Where the fold is, in a box the list's own body never opens.
    ///
    /// This was two pieces of `@State`, which is the obvious way to write it and the reason
    /// scrolling a real timeline was unusable. `@State` read anywhere in `body` makes every write
    /// invalidate the whole view — and this one is written each time a row crosses the top edge.
    /// Re-evaluating `body` re-runs the `@Query`, and a `@Query` over a few thousand items costs a
    /// quarter of a second before it returns anything. Measured with `sample` on the running app
    /// against 4,818 items: three body evaluations during a six-second scroll, `items.getter`
    /// accounting for most of the wall clock in each.
    ///
    /// As an `@Observable` reference the dependency is taken by whoever *reads* it, and the two
    /// readers — the subtitle and the position menu's label — are their own small views. The list
    /// does not read it, so the list does not re-fetch. Nothing about the fold's behaviour changes;
    /// only who is invalidated when it moves.
    @State private var fold = FoldState()

    /// One probe per list, on both platforms. See `TimelineFoldReader` for why this is not a
    /// SwiftUI-only affair.
    @State private var foldHandle = TimelineFoldReader.Handle()

    /// The fold being pinned against the top edge while items arrive above it, if any.
    ///
    /// Also the flag that makes ``readFold()`` stand down for the duration — see there.
    @State private var heldAnchorID: String?

    /// When ``heldAnchorID`` was set, so a hold cannot outlive its insertion indefinitely.
    @State private var heldAnchorAt: ContinuousClock.Instant?

    /// The in-flight retry loop, cancelled by the next arrival so two holds cannot fight.
    @State private var anchorHold: Task<Void, Never>?

    /// Whether the scope has finished opening at its stored position.
    ///
    /// The restore scrolls programmatically, which moves the fold; without this the first thing
    /// every appearance would do is write the positions it passed through on the way.
    @State private var hasRestored = false

    /// The foreign position this list has already moved to, as the sending device wrote it.
    ///
    /// Guards against adopting the same report twice, which is what made the list jump: the
    /// translated key it was keyed on is a store lookup, so an ordinary refresh changes it without
    /// any device having reported anything — see ``ForeignPosition``.
    @State private var adoptedForeignMark: SortKey?

    /// The fold as last written to the store.
    ///
    /// Kept so a write can be skipped when nothing has moved — see ``canCommitFold``. Deliberately
    /// per-list rather than read back out of the store: what matters is whether *this* view has
    /// already reported this fold, not what some other device last said.
    @State private var lastWrittenFoldID: String?

    /// Derived from the two small queries above, and rebuilt only when they change.
    ///
    /// These were computed properties, which meant a fresh `Dictionary` and `Set` on *every body
    /// evaluation* — and the body re-evaluates as the fold moves. With a handful of feeds that was
    /// invisible; with a real subscription list and a long Read Later pile it is allocation on the
    /// main thread in the middle of a scroll.
    @State private var sourceTitles: [String: String] = [:]
    @State private var sourceIcons: [String: String] = [:]
    @State private var savedItemIDs: Set<String> = []


    private static func titles(of sources: [CachedSource]) -> [String: String] {
        Dictionary(sources.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
    }

    /// Feed id to favicon URL, for the rows.
    ///
    /// A second dictionary rather than a struct holding both, because they are consumed by
    /// different things: a row needs the icon, and `toggleReadLater` needs the title for the Read
    /// Later snapshot. Feeds without one are left out rather than stored as `nil`, so the lookup
    /// answers the row's actual question.
    private static func icons(of sources: [CachedSource]) -> [String: String] {
        Dictionary(
            sources.compactMap { source in source.iconURLString.map { (source.id, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// How far the list must scroll before the fold is looked at again.
    ///
    /// Small enough that the count never visibly lags the scroll, large enough that a flick does
    /// not ask sixty times a second.
    private static let foldSampleStride: CGFloat = 8

    /// Pulls the current fold into observable state.
    ///
    /// The handle is a plain reference, so nothing re-renders when the table scrolls; the scroll
    /// geometry callback is the trigger that turns an AppKit fact into SwiftUI state.
    private func readFold() {
        // One reading, used twice. Asking the handle again below would be a second look at the
        // geometry, and two looks can disagree — see `Handle.foldReading`.
        let reading = foldHandle.foldReading

        // Recorded first, and ungated, because an anchor has to be what is on screen *now* even
        // when the fold is deliberately standing still. See `FoldState.anchorItemID`.
        if let reading, items.indices.contains(reading.row) {
            fold.anchorItemID = items[reading.row].id
            fold.anchorOffset = reading.offset
        }

        guard isHoldReleased() else { return }

        guard let reading, items.indices.contains(reading.row) else {
            guard fold.row != nil || fold.itemID != nil else { return }
            fold.move(to: nil, row: nil, in: scope)
            counts.reportLiveCount(nil, for: scope)
            return
        }

        let row = reading.row

        // The scroll callback fires every frame; the row it resolves to changes only when one
        // scrolls past the top edge. Writing state on every frame re-rendered the whole list
        // sixty times a second — which on an iPhone is the difference between scrolling smoothly
        // and not scrolling at all.
        guard row != fold.row else { return }

        // Read from the screen, so this is the reader's own doing and may be reported as such.
        fold.adoptedItemID = nil
        fold.move(to: items[row].id, row: row, in: scope)
        // Reported into the shared counts so the sidebar badge moves with the list rather than
        // trailing the debounced write by a second and a half.
        counts.reportLiveCount(row, for: scope)
    }

    /// Whether the fold may be read from the screen again after items arrived above it.
    ///
    /// ## Why a timer is not good enough here
    ///
    /// The pin in ``holdScrollAnchor(previousNewest:proxy:)`` is best-effort: it is asking a table
    /// to scroll to a row that was inserted moments ago, and whether it lands depends on layout
    /// this code does not control. What must *not* depend on that is the reading position. If the
    /// pin misses, the list is left at the top showing the new arrivals — and the very next scroll
    /// callback would read the fold from that geometry, find row 0, and commit the newest arrival
    /// as the reading position. Which is the bug: a refresh marking everything it just fetched as
    /// read, with no read/unread state left to recover from.
    ///
    /// So the hold is released by evidence rather than after a delay. Anything at or below the row
    /// being held is trustworthy: either the pin landed, or the reader has scrolled on past it.
    /// Anything above it is ambiguous — an insertion produces exactly that, and so does scrolling
    /// up into the arrivals — and in both cases the honest answer is that the fold has not moved.
    ///
    /// Costing nothing, because the position only ever advances within a generation: a fold held
    /// still while the reader looks *up* at what arrived cannot write anything anyway.
    private func isHoldReleased() -> Bool {
        guard let held = heldAnchorID else { return true }

        // A held item that has left the scope — pruned, filtered, or its account switched off —
        // passes `heldRow: nil`, and there is then nothing to hold against.
        guard FoldHold.isReleased(
            liveRow: foldHandle.foldRow,
            heldRow: rowOfItem(held),
            readerIsScrolling: foldHandle.isReaderScrolling,
            heldFor: heldAnchorAt?.duration(to: .now),
            limit: Self.foldHoldLimit
        ) else {
            return false
        }

        heldAnchorID = nil
        heldAnchorAt = nil
        // The evidence that releases the fold reading is the reader having scrolled to or past the
        // held row, and from then on the pin has nothing left to protect. Left armed it would keep
        // correcting for the rest of its window, against a reader who is now moving on purpose.
        foldHandle.releaseAnchor()
        return true
    }

    private var foldItem: CachedItem? {
        item(withID: fold.itemID)
    }

    /// One item by id, through its unique index.
    ///
    /// Replaces `items.first { $0.id == id }`. That reads plausibly and is a linear scan over
    /// every row in the scope, touching a SwiftData property on each — and the toolbar alone asked
    /// for the selected item five times per body evaluation, while the body re-evaluates every
    /// time the fold crosses a row. In the same profile that caught the fetch above, `CachedItem
    /// .id.getter` was the single hottest symbol in the app.
    private func item(withID id: String?) -> CachedItem? {
        guard let id else { return nil }
        var descriptor = FetchDescriptor<CachedItem>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    private var isLateArrivalList: Bool {
        if case .lateArrivals = scope { return true }
        return false
    }

    /// Whether this scope has a reading position at all.
    ///
    /// Older Items is included. It is still emptied by dismissing rather than by the marker
    /// passing over it — the marker is what stops its badge counting items you have already
    /// scrolled through, which is a different job from clearing the flag.
    private var isPositioned: Bool { true }

    private var selectedItem: CachedItem? {
        item(withID: selectedItemID)
    }


    /// `ScrollViewReader` rather than the `ScrollPosition` binding.
    ///
    /// `.scrollPosition($position)` is the newer API and reads better, but it does not drive a
    /// `List` — verified against the running app, where the restore silently did nothing and left
    /// the timeline at the top. Every scroll here is by row id, which is exactly what the proxy
    /// does, so nothing is lost by using it.
    var body: some View {
        ScrollViewReader { proxy in
            List(selection: $selectedItemID) {
                ForEach(items) { item in
                    let isSaved = savedItemIDs.contains(item.id)

                    ItemRow(
                        item: item,
                        sourceTitle: sourceTitles[item.sourceID],
                        sourceIconURLString: sourceIcons[item.sourceID],
                        // Every row in Older Items shares that state, so the badge would be noise
                        // rather than the explanation it is in a mixed timeline.
                        showsLateArrival: !isLateArrivalList && settings.reading.showsLateArrivalBadges,
                        headingScale: settings.reading.listHeadingScale,
                        bodyScale: settings.reading.listBodyScale,
                        lineHeight: settings.reading.contentLineHeight
                    )
                        // No `.tag()` and no `.id()`. `ForEach` over `Identifiable` elements
                        // already gives every row its item's id as both its selection tag and its
                        // scroll target, and adding them explicitly made SwiftUI construct each
                        // row's view in order to read them back — for all of them, on every
                        // selection change, rather than for the fifteen on screen.
                        // Grey where a `List` would fill in the accent colour, with the accent
                        // spent on an outline instead. See `SelectionMarker`.
                        .listRowBackground(SelectionMarker(isSelected: selectedItemID == item.id))
                        // Leading edge, so the gesture is a swipe to the *right*, and `allowsFullSwipe`
                        // so a decisive swipe saves without waiting for the button to be tapped.
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            Button(
                                isSaved ? "Remove from Read Later" : "Read Later",
                                systemImage: isSaved ? "bookmark.slash" : "bookmark"
                            ) {
                                toggleReadLater(item)
                            }
                            .tint(.orange)
                        }
                        .contextMenu {
                            // First, because for a post it is the thing most often wanted from
                            // this menu, and because Read Later is also reachable by swiping.
                            StatusActionMenu(
                                item: item,
                                accounts: StatusInteractions.Actor.menuOrder(
                                    for: accounts,
                                    owner: item.accountID
                                )
                            )

                            if item.kind == .status, !accounts.isEmpty {
                                Divider()
                            }

                            Button(
                                isSaved ? "Remove from Read Later" : "Read Later",
                                systemImage: isSaved ? "bookmark.slash" : "bookmark"
                            ) {
                                toggleReadLater(item)
                            }

                            if let url = item.url {
                                Divider()
                                Link("Open in Browser", destination: url)
                                // Beside Open in Browser because it is the other half of the same
                                // question — this link, but taken somewhere else rather than
                                // followed here. Both representations go on the pasteboard; see
                                // `LinkActions.copy(_:)`.
                                Button("Copy Link", systemImage: "link") {
                                    LinkActions.copy(url)
                                }
                            }

                            if isLateArrivalList {
                                Divider()
                                Button("Dismiss", systemImage: "checkmark") {
                                    item.arrivedLate = false
                                    save()
                                }
                            }
                        }
                }
            }
            // One probe for the whole list. See `TimelineFoldReader` for why this must not be
            // attached per row.
            .background { TimelineFoldReader(handle: foldHandle) }
            .plainListSelection()
            // Quantised to whole steps of `foldSampleStride`, not raw offset. `onScrollGeometryChange`
            // only calls `action` when the mapped value *changes*, so mapping to the offset itself
            // means one call per frame for the whole of a scroll; rounding to a step means one call
            // per few points of travel. The fold cannot move faster than that anyway — it changes
            // when a row crosses the top edge.
            .onScrollGeometryChange(for: Int.self) { geometry in
                Int((geometry.contentOffset.y / Self.foldSampleStride).rounded())
            } action: { _, _ in
                // Noted before the fold is read, and noted even when the reading is unchanged:
                // this is what tells the commit that scrolling is still happening. `readFold`
                // returns early most of the time, so recording it in there would miss most of a
                // scroll.
                fold.lastScrollAt = .now
                readFold()
            }
            .overlay {
                if items.isEmpty {
                    ContentUnavailableView(
                        "No Items",
                        systemImage: "tray",
                        description: Text("Items appear here once this source has been refreshed.")
                    )
                }
            }
            .toolbar {
                // Read Later, Open in Browser and Share are the reading pane's, next to the item
                // they act on — see `DetailView.itemActions`. On a merged macOS toolbar there is
                // one strip for the whole window, so a button here and a button there are simply
                // two buttons, and having both was what that looked like.
                //
                // The keys those buttons carry are still handled over the list, by `onKeyPress`
                // above, because a bare letter does not reliably reach a toolbar shortcut from
                // here.

                // Refresh belongs to the list it refills, so it is declared with the list —
                // see the note where `TimelineView` no longer declares one.
                ToolbarItem(placement: .primaryAction) {
                    RefreshToolbarButton()
                }

                ToolbarItem(placement: .primaryAction) {
                    if case .lateArrivals = scope {
                        // No reading position to show: this list is emptied by dismissing, not by
                        // a marker moving through it.
                        Button("Dismiss All", systemImage: "checkmark.circle") {
                            dismissAllLateArrivals()
                        }
                        .disabled(items.isEmpty)
                        .toolbarButtonHelp("Dismiss All")
                    } else {
                        positionMenu(proxy)
                    }
                }
            }
            // Everything below this line depends on the column being focused, and clicking a row
            // does not focus it — the selection moves and the focus does not, so after a click the
            // keyboard was dead over the list it had just been used on. See
            // ``SwiftUICore/View/activatesColumn(_:onSelecting:moveFocus:)``.
            .activatesColumn(.timeline, onSelecting: selectedItemID, moveFocus: moveFocus)
            // Left returns focus to the sidebar. Up/down are left alone so the list keeps its own
            // native selection movement, which is what makes arrow-key navigation feel right.
            .onKeyPress(.leftArrow) {
                moveFocus(.sidebar)
                return .handled
            }
            .onKeyPress(.rightArrow) {
                moveFocus(.detail)
                return .handled
            }
            // The configurable shortcuts, handled here as well as on the buttons that own them.
            //
            // Not redundant. A `keyboardShortcut` with no modifier does not reliably beat an
            // `NSTableView`'s type-select: pressing `L` over the timeline moved the selection to
            // the next item beginning with "l" and saved nothing, which is also the likeliest
            // explanation for `k` never having worked. A key equivalent that *does* fire consumes
            // the event before `onKeyPress` is ever called, so the two cannot both run.
            .onKeyPress(phases: .down) { press in
                handleShortcut(press)
            }
            .task {
                await restorePosition(proxy)
            }
            // Drawn behind the list, like the fold sink, so observing position rows takes its
            // dependency there rather than in the list body.
            .background {
                TimelinePositionWatcher(scope: scope, itemCount: items.count) { position in
                    await adoptRemotePosition(position, proxy: proxy)
                }
            }
            // The count rather than the newest id, which is what this watched before.
            //
            // An arrival does not have to be the newest item to displace the reader: a FreshRSS
            // walk commits items whose published dates interleave with what is already there, so
            // a batch can land entirely *below* the top row and still push the fold down the
            // screen. Keyed on the newest id, none of those were held at all.
            .onChange(of: items.count) { previousCount, _ in
                // Retried until it lands. The first attempt runs as the view appears, which on a
                // launch — or on a second device whose first sync has only just brought the
                // position in — can be before the items it has to scroll to exist.
                guard hasRestored else {
                    Task { await restorePosition(proxy) }
                    return
                }
                holdScrollAnchor(previousCount: previousCount, proxy: proxy)
            }
            // An arrival can put a freshly flagged row on screen without the fold ever moving, and
            // the commit's clearing only runs when the fold changes. So the other half of it lives
            // here, where the rows land.
            //
            // Deferred, because the indices are read from the backing view's layout and reading
            // them mid-insertion names the wrong items — and because an arrival above the reader
            // arms a hold that is still moving the list for a while afterwards. A `.task(id:)`
            // rather than a loose `Task`, so leaving the list cancels it: a stale clearing pass
            // would be applying one scope's row indices to another scope's items.
            .task(id: items.count) {
                try? await Task.sleep(for: Self.arrivalSettleDelay)
                guard !Task.isCancelled, hasRestored else { return }
                clearSeenLateArrivals()
            }
            .task(id: sources.count) {
                sourceTitles = Self.titles(of: sources)
                sourceIcons = Self.icons(of: sources)
            }
            .task(id: readLaterEntries.count) {
                savedItemIDs = Set(readLaterEntries.map(\.itemID))
            }
            .onDisappear {
                // Written now rather than left pending, and this is not belt-and-braces: the
                // debounce above lives in a `.task`, and a `.task` is cancelled when its view
                // disappears. So the last second and a half of reading was only ever *pending*
                // when the list went away — which on iPhone is what tapping a row does. Scroll,
                // open an item, and the position you scrolled to was never written at all.
                //
                // Leaving the screen is the same kind of event as leaving the app, and gets the
                // same treatment: the fold on screen is final, so there is nothing left to debounce.
                flushPosition()

                // Otherwise this scope's badge would keep showing the count from whenever its
                // list was last on screen.
                counts.clearLiveCount(for: scope)
                // A hold outliving its list would correct whatever backing view the handle now
                // points at.
                anchorHold?.cancel()
                foldHandle.releaseAnchor()
                heldAnchorID = nil
                heldAnchorAt = nil
            }
            // Delivered synchronously on the main thread by the poster, which is what makes this
            // usable at termination: the write and its `save()` complete before the app exits.
            .onReceive(NotificationCenter.default.publisher(for: Self.leavingForegroundNotification)) { _ in
                flushPosition()
            }
            // Attached here, beside the count it reports, rather than in the parent. Feeding the
            // live count upwards re-rendered the whole timeline view on every scroll callback,
            // which cost the list its keyboard focus: exactly one page-down would work and every
            // key after it went nowhere.
            .background {
                TimelineFoldSink(
                    fold: fold,
                    scope: scope,
                    counts: counts,
                    isReady: hasRestored,
                    commit: { await commitPosition() }
                )
            }
        }
    }

    // MARK: - The "N newer" menu

    @ViewBuilder
    private func positionMenu(_ proxy: ScrollViewProxy) -> some View {
        Menu {
            Button("Scroll to Timeline Position", systemImage: "arrow.down.to.line") {
                scrollToStoredPosition(proxy)
            }

            Button("Scroll to Top", systemImage: "arrow.up.to.line") {
                guard let newest = items.first else { return }
                proxy.scrollTo(newest.id, anchor: .top)
            }

            Button("Scroll Selection to Top", systemImage: "text.insert") {
                guard let selected = selectedItem else { return }
                proxy.scrollTo(selected.id, anchor: .top)
            }
            .disabled(selectedItemID == nil)
        } label: {
            TimelineCountLabel(fold: fold, scope: scope, counts: counts)
        }
        // A count is the point of the button, so it must not be reduced to an icon.
        .labelStyle(.titleAndIcon)
        .help("Reading position")
    }

    /// Returns to the position held in the store, which is only somewhere else when it came from
    /// another device or from a previous session.
    ///
    /// Every entry in this menu now scrolls, and that is the honest shape of it: the position *is*
    /// the fold, so there is no state left to set independently of the view. The previous menu had
    /// "Mark Position Here" and "Mark All Older", which wrote a position without moving — under
    /// these semantics the next fold reading simply overwrote both a second later.
    private func scrollToStoredPosition(_ proxy: ScrollViewProxy) {
        guard let item = try? ThresholdService.itemAtPosition(for: scope, in: modelContext) else { return }
        proxy.scrollTo(item.id, anchor: .top)
    }

    /// Saves the item for later, or removes it if it is already saved.
    ///
    /// The snapshot is taken here rather than when the list is next opened, because by then the
    /// cached item may have been pruned — which is the whole reason `ReadLaterEntry` copies
    /// everything it needs instead of pointing at a row.
    /// Runs a configured shortcut, or declines the key so the list keeps its own behaviour.
    ///
    /// Declining matters as much as handling: every keystroke over the timeline arrives here, and
    /// swallowing the ones that are not bound would take away type-select, `Space` and everything
    /// else the list does for itself.
    private func handleShortcut(_ press: KeyPress) -> KeyPress.Result {
        guard let item = selectedItem else { return .ignored }

        if settings.shortcuts.readLater.matches(press) {
            toggleReadLater(item)
            return .handled
        }
        if settings.shortcuts.openInBrowser.matches(press), let url = item.url {
            // Behind the app where the platform allows it — working down a list is the case this
            // key exists for, and a browser jumping in front on each press ends the pass. See
            // `LinkActions.openForShortcut(_:otherwise:)`.
            LinkActions.openForShortcut(url, otherwise: openURL)
            return .handled
        }
        return .ignored
    }

    private func toggleReadLater(_ item: CachedItem) {
        do {
            let result = try ReadLaterService.toggle(
                item,
                sourceTitle: sourceTitles[item.sourceID] ?? "",
                sourceIconURLString: sourceIcons[item.sourceID],
                archiveContent: settings.reading.archivesReadLaterContent,
                in: modelContext
            )
            try SyncOutbox.record(result, in: modelContext)
        } catch {
            return
        }
        services.syncSoon()
        save()
    }

    /// Clears the flag on everything in the list, emptying it.
    private func dismissAllLateArrivals() {
        _ = try? ThresholdService.clearLateArrivals(for: scope, in: modelContext)
        save()
    }

    /// The items the reader can see right now: the fold, and everything below it that fits on
    /// screen.
    private var visibleItems: ArraySlice<CachedItem> {
        guard let rows = VisibleRows.clamped(foldHandle.visibleRows, count: items.count) else {
            return []
        }
        return items[rows]
    }

    /// Whether anything on screen is still marked as an older item.
    ///
    /// Asked before the commit's debounce so a settle with nothing to do costs one look at the
    /// geometry rather than a wait.
    private var isShowingLateArrival: Bool {
        guard !isLateArrivalList else { return false }
        return visibleItems.contains(where: \.arrivedLate)
    }

    /// Takes the older-item mark off everything the reader can see.
    ///
    /// ## Why being on screen is enough
    ///
    /// Older Items exists so that an item which lands *below* the reading position is not simply
    /// lost — chronological order would file it beneath where the reader has been and they would
    /// never come across it. That is a statement about what is off screen. An item sitting a few
    /// rows under the fold has not been missed, it is being looked at, and announcing it as an
    /// older item is telling the reader they have missed something that is in front of them.
    ///
    /// So seeing an item is a dismissal of it, on the same terms as the Dismiss button and with
    /// the same effect: the flag is this device's own and is never synced, so nothing is pushed.
    ///
    /// Not in the Older Items list itself, where the flag *is* the list. Scrolling through it
    /// would empty it row by row under the reader, and a list that disappears as you read it
    /// cannot be worked through. It has Dismiss and Dismiss All for that, which are decisions
    /// rather than side effects.
    private func clearSeenLateArrivals() {
        guard !isLateArrivalList else { return }
        let seen = visibleItems.filter(\.arrivedLate)
        guard !seen.isEmpty else { return }

        for item in seen {
            item.arrivedLate = false
        }
        save()
    }

    // MARK: - Position tracking

    /// Opens the scope at its stored position.
    ///
    /// Opening at the position rather than at the top is what makes the position worth syncing:
    /// you pick up a second device where you left the first, and the newer items sit above the
    /// fold with the count saying how many.
    ///
    /// ## Why it waits before reading the store
    ///
    /// "Where was I" is a question about every device, so it cannot be answered from a store that
    /// has not heard from them yet. Restoring first and correcting afterwards is what the app used
    /// to do — the list opened at yesterday's place and `adoptRemotePosition` moved it once the
    /// pull landed — and it put the reader somewhere wrong for as long as the pull took, which is
    /// exactly the window in which their first scroll overwrote the position they were about to be
    /// given. Waiting is bounded by `AppServices.positionMergeTimeout`, and the gate opens on a
    /// failed or unconfigured sync as readily as on a successful one, so an offline device still
    /// opens where it left off.
    private func restorePosition(_ proxy: ScrollViewProxy) async {
        // Before anything is read, including the early-outs below: `hasRestored` is what releases
        // adoption, and setting it from a pre-merge reading would let the rest of the view act on
        // a position this device is still in the middle of being corrected about.
        await services.waitForPositionMerge()
        guard !Task.isCancelled else { return }

        // Whether the fold has to be measured at the end, or is already known.
        var restoredRow: Int?

        // Whether the stored position could actually be placed in the list.
        //
        // This is the difference between "there is nowhere to restore to" and "there is somewhere
        // and I cannot see it yet", and conflating them corrupted the position. The old code fell
        // through to `readFold()` in both cases, which reads the *geometry* — a list that has not
        // laid out its rows yet reads as row 0 — and the commit a second later wrote that as the
        // reading position and pushed it to every other device. Launching the app therefore threw
        // away where you were and reported "up to date", and the other device dutifully agreed.
        //
        // A store whose items have not arrived yet is the ordinary case on a freshly synced second
        // device, and it was exactly the case that destroyed the position it had just pulled.
        var couldPlace = true

        defer {
            // Left `false` when the position is real but unplaceable, which suppresses the commit
            // entirely — better to hold the stored position untouched and try again when the rows
            // arrive than to overwrite it with a guess. `onChange(of: items.count)` retries.
            hasRestored = couldPlace
            if let restoredRow {
                // Taken from the stored position rather than measured back off the screen.
                //
                // Measuring is what caused the position to creep. `scrollTo(anchor: .top)` lands
                // the row within a fraction of a point of the viewport's top edge, and now that a
                // row has to be *entirely* below that edge to count as read, landing a hair high
                // reads as one row further down. The restore then committed that, so the count
                // grew by one every few launches with nobody having scrolled — measured at
                // 18 → 18 → 19 → 19 across three relaunches.
                //
                // The restore already knows the answer it is scrolling towards, so it says so.
                // Every later reading comes from geometry as usual, because from then on the
                // geometry is the truth.
                fold.move(
                    to: items.indices.contains(restoredRow) ? items[restoredRow].id : nil,
                    row: restoredRow,
                    in: scope
                )
                // Marked as the restore's own, so the commit does not republish it. See
                // `FoldState.restoredItemID`.
                fold.restoredItemID = fold.itemID
                counts.reportLiveCount(restoredRow, for: scope)
            } else {
                readFold()
                fold.restoredItemID = fold.itemID
            }
        }

        // A hold left over from an arrival would correct the restore's own scrolling straight back
        // out again. A deliberate scroll always outranks a pin.
        foldHandle.releaseAnchor()

        // Older Items carries no position — every item in it already sits below one — so there is
        // nothing to restore and nothing to write.
        guard isPositioned else { return }

        guard let item = try? ThresholdService.itemAtPosition(for: scope, in: modelContext) else {
            // Nothing to place against. Only safe to treat as "start at the top" when there is no
            // stored position at all — otherwise the rows simply are not loaded yet.
            let stored = (try? ThresholdService.effectivePosition(for: scope, in: modelContext))?
                .markSortKey ?? .distantPast
            couldPlace = stored == .distantPast
            return
        }

        // The row index *is* the stored count: the items above the fold are exactly `0..<count`.
        restoredRow = try? ThresholdService.newerCount(for: scope, in: modelContext)

        #if os(macOS)
        // Selecting as well as scrolling, so the arrow keys start from where reading left off
        // rather than jumping to the newest row on the first press.
        //
        // macOS only. On iPhone the split view is collapsed into a push stack, so a non-nil
        // selection is not a highlighted row — it is a *pushed screen*. Choosing All Items in the
        // sidebar landed the reader inside an article they never tapped.
        if selectedItemID == nil {
            selectedItemID = item.id
        }
        #endif

        // Scrolled twice, because rows here have variable heights and a `List` lays them out
        // lazily: the first scroll is computed from the placeholder heights of the rows above the
        // target and measurably lands a row or two short. The second pass, once nearby rows have
        // real heights, lands it.
        //
        // Both passes are timed. `scrollTo` on a lazily-measured list is the one call here that
        // can block for as long as it takes to lay out every row above the target, and switching
        // back to a large scope is where that would show — so when the app stalls on a scope
        // change, this says whether the stall is here or somewhere else entirely.
        ScrollDiagnostics.shared.attribute("restore → row \(restoredRow ?? -1)")
        ScrollDiagnostics.shared.time("restore scrollTo (first pass), row \(restoredRow ?? -1)") {
            proxy.scrollTo(item.id, anchor: .top)
        }
        try? await Task.sleep(for: Self.restoreSettleDelay)
        ScrollDiagnostics.shared.attribute("restore (second pass) → row \(restoredRow ?? -1)")
        ScrollDiagnostics.shared.time("restore scrollTo (second pass)") {
            proxy.scrollTo(item.id, anchor: .top)
        }
        try? await Task.sleep(for: Self.restoreSettleDelay)
    }

    /// Moves the list to a position another device reported.
    ///
    /// The counterpart to ``restorePosition(_:)``, for a position that arrives while the list is
    /// already open. Without it a synced position only ever took effect on the *next* launch, and
    /// in the meantime this device's own fold overwrote it.
    ///
    /// Deliberately does not write anything. This device adopting a position is not this device
    /// reporting one, and committing here would give the adopted row a fresh timestamp under this
    /// device's id — which is how two devices end up echoing a position back and forth for ever,
    /// each one's "adoption" outranking the other's. The row this scrolled to is already the
    /// winning row; there is nothing to say about it.
    private func adoptRemotePosition(_ position: ForeignPosition, proxy: ScrollViewProxy) async {
        // Not before the initial restore: the two would race to scroll, and the restore is the one
        // that knows whether it managed to place itself at all. Deliberately not recorded as
        // adopted — there is a real report here still waiting to be applied.
        guard hasRestored, isPositioned else { return }

        // ## What each answer is for
        //
        // A report is applied once, keyed on what the other device *wrote* rather than on what
        // this store made of it. It used to be applied every time its translation changed, and
        // that translation is a store lookup — so an ordinary refresh re-fired it with nothing
        // having been reported by anybody. The reader, meanwhile, had scrolled on, so the list was
        // scrolled back: a couple of items, snapped to the top, mid-scroll, every refresh.
        //
        // And a report whose article is not here yet is **left unrecorded**, so it lands the
        // moment ingest brings the article in. That is the case this whole mechanism exists for,
        // and the one it used to get wrong — see `PositionAdoption`.
        switch PositionAdoption.decide(
            isAlreadyAdopted: adoptedForeignMark == position.reported,
            isPlaceable: position.isPlaceable,
            // Already where it wants to be — the common case, because this device's own pushes
            // come back from the server under its own id and every scope it cascaded to reports
            // the same key.
            isFoldAtReport: foldItem?.sortKey == position.local
        ) {
        case .ignore, .waitForItems:
            return
        case .recordOnly:
            adoptedForeignMark = position.reported
            return
        case .scroll:
            break
        }

        // Placeable, so these answer about the article the report actually names rather than about
        // whichever row an offset happened to land on.
        guard
            let item = try? ThresholdService.itemAtPosition(for: scope, in: modelContext),
            let row = try? ThresholdService.newerCount(for: scope, in: modelContext)
        else { return }

        adoptedForeignMark = position.reported

        // As in the restore: a pin from a concurrent arrival must not undo a position this device
        // has just been told to move to.
        foldHandle.releaseAnchor()
        ScrollDiagnostics.shared.attribute("adopt → row \(row)")

        // Two passes with a settle between, exactly as the restore does — and for a reason that
        // only became true when adoption started waiting for the article it names.
        //
        // A report used to be applied the moment the *mark* arrived, which is a position-only
        // change: the rows were already there and one `scrollTo` landed. Now the interesting case
        // is a report that arrives ahead of its article, so it is applied when **ingest brings the
        // rows in** — and a proxy scroll issued from inside the update that inserted them is
        // exactly the call `holdScrollAnchor` documents as landing on nothing, because the backing
        // table has not been handed the new rows yet. On top of that the rows have variable
        // heights and are measured lazily, so a first pass computed from placeholder heights lands
        // a row or two short.
        //
        // The anchor is released again before the second pass: another batch landing in between
        // would arm a hold of its own, and a hold that outlives this scroll drags the reader back
        // to where they were before they were told to move.
        proxy.scrollTo(item.id, anchor: .top)
        try? await Task.sleep(for: Self.restoreSettleDelay)
        foldHandle.releaseAnchor()
        proxy.scrollTo(item.id, anchor: .top)
        // Deliberately no cancellation check around the bookkeeping below. A cancelled task here
        // means the list is going away, and returning early would leave the report recorded as
        // applied — it is claimed before the scroll — with the fold never moved to match it.

        // Set from the stored count rather than measured back off the screen, for the same reason
        // the restore does it: `scrollTo` lands within a fraction of a point of the top edge and
        // measuring it reads a row late, which the next commit would then write down as a move
        // nobody made.
        fold.adoptedItemID = item.id
        fold.move(to: item.id, row: row, in: scope)
        counts.reportLiveCount(row, for: scope)

        // Forgotten deliberately. `canCommitFold` skips a fold this view has already written, and
        // the winning position has just moved out from under that record: without this, scrolling
        // back to the row last written here would match it and be skipped, leaving this device
        // silently unable to report the one position it is sitting on.
        lastWrittenFoldID = nil
    }

    /// Writes the settled fold position, and those of the scopes it overlaps.
    ///
    /// Free to move in either direction — see `ThresholdService.setPosition`. Because it can only
    /// ever be wrong until the next scroll, and a wrong position is corrected simply by scrolling,
    /// none of the guards the previous high-water design needed apply here.
    private func commitPosition() async {
        // Two reasons to wait out a settle: a position worth writing, and rows on screen still
        // marked as older items. The second is why this no longer returns on `canCommitFold`
        // alone — a reader whose fold cannot be published, because it was restored or adopted, is
        // still a reader looking at those rows.
        guard canCommitFold || isShowingLateArrival else { return }

        // ## Why this waits in a loop rather than once
        //
        // `.task(id:)` restarts this whenever the *fold* changes, and the fold changes when a row
        // crosses the top edge. That is a good enough debounce for flicking through a scope and
        // not for reading one: scrolling slowly through a long post holds the fold still for
        // longer than the delay, so the write — a cascade of rows and a save — landed in the
        // middle of the gesture. Which is precisely when there is a frame budget to blow.
        //
        // So the question asked here is the one that actually matters: has the list stopped
        // moving. Every scroll callback stamps `fold.lastScrollAt`, and this waits until the last
        // stamp is a whole delay old.
        //
        // ## Waiting out the *remainder*, which the first version of this did not
        //
        // It slept a whole delay per pass, which is a different rule wearing the same clothes: a
        // fold that changed a moment before the scroll ended woke at 1.3 s, found 0.2 s of quiet
        // owed, and slept another full 1.5 s — so the write landed nearly three seconds after the
        // reader stopped rather than one and a half. On iPhone that is long enough to be a bug
        // rather than a delay: tapping a row takes the list off screen, which cancels this task,
        // and scrolling and then opening an item immediately lost the position outright. Topping
        // up by what is actually owed keeps the rule and halves the window.
        //
        // A reader who never stops scrolling never gets a write, which is correct — the fold they
        // end on is the one worth recording, and both leaving the screen and leaving the app write
        // it immediately by another route. See ``flushPosition()``.
        var remaining = Self.commitDelay
        while remaining > .zero {
            do {
                try await Task.sleep(for: remaining)
            } catch {
                // Cancelled by a newer fold; that one will write instead.
                return
            }
            remaining = PositionDebounce.remainingQuiet(
                sinceLastScroll: fold.lastScrollAt?.duration(to: .now),
                delay: Self.commitDelay
            )
        }

        // After the settle rather than before it, so the rows being read off the geometry are the
        // ones standing still in front of the reader.
        clearSeenLateArrivals()

        // Guarded again inside, so a fold that only got here to clear the marks above writes
        // nothing.
        await writePosition()
    }

    /// Whether the fold is this device's own, settled, and worth writing.
    private var canCommitFold: Bool {
        guard hasRestored, isPositioned, let itemID = fold.itemID else { return false }

        // An adopted fold is the other device's report, not this device's. Writing it back would
        // restamp it under this device's id and start the two of them echoing it. See
        // `FoldState.adoptedItemID`.
        guard itemID != fold.adoptedItemID else { return false }

        // Already written by this view, so there is nothing to say. Cheap, and it saves the fetch
        // below in the common case.
        guard itemID != lastWrittenFoldID else { return false }

        guard let item = foldItem else { return false }

        // The store's own answer rather than anything this view remembers. `lastWrittenFoldID`
        // cannot stand in for it: it covers what *this view* has written, and a list that has just
        // restored has written nothing while sitting exactly on the stored position — which is the
        // case that was republishing a stale position on every launch.
        return PositionPublication.shouldPublish(
            fold: item.sortKey,
            stored: (try? ThresholdService.effectivePosition(for: scope, in: modelContext))?.markSortKey,
            isRestoredFold: itemID == fold.restoredItemID,
            foldScope: fold.scope,
            writingScope: scope,
            // Read here rather than taken as a view dependency: this runs from the debounce and
            // from the flush, neither of which is a body evaluation, so nothing is invalidated by
            // asking. `TimelineFoldSink` is what notices the gate opening.
            arePositionsMerged: services.arePositionsMerged
        )
    }

    /// Writes the settled fold, off the main actor.
    ///
    /// The write is more than it looks like — a row and an outbox record per scope the current one
    /// overlaps, then a `save()` — and it used to happen on the main context, which is to say in
    /// the middle of reading. `AppServices.commitPosition` performs it on a context of its own;
    /// see ``PositionWriter``.
    ///
    /// Nothing is awaited before the bookkeeping below, deliberately: `lastWrittenFoldID` is
    /// claimed *first*, so a second commit arriving during the hop does not write the same fold
    /// again, and is given back if the write turns out to have had nothing to write.
    private func writePosition() async {
        guard canCommitFold, let itemID = fold.itemID else { return }

        lastWrittenFoldID = itemID
        guard await services.commitPosition(scope: scope, itemID: itemID) else {
            // The item had left the store between the fold being read and the debounce elapsing —
            // pruned, filtered, or its account switched off. Nothing was written, so nothing has
            // been reported either.
            if lastWrittenFoldID == itemID { lastWrittenFoldID = nil }
            return
        }
    }

    /// Writes the fold on the way out, without waiting for the debounce.
    ///
    /// The debounce means the last second and a half of reading is only ever *pending*, and there
    /// are two ways to leave inside that window. Quitting — swipe the app away, press ⌘Q — kills
    /// the task holding the sleep along with the process. Navigating away kills it too: a `.task`
    /// is cancelled when its view disappears, and on iPhone opening an item takes the list off
    /// screen. Both land exactly where they are most noticeable, because reading and then closing
    /// or opening something is what people do.
    ///
    /// `willTerminate` on the Mac rather than `willResignActive`: switching apps must not write
    /// anything, or every ⌘-Tab would queue a sync push. On iOS `didEnterBackground` is both the
    /// last moment the process is guaranteed to run and the state it is usually killed from. And
    /// `onDisappear` for the navigation case, which covers switching scopes on the Mac as well.
    private func flushPosition() {
        // The unchanged-position test used to live here and only here, which is exactly why the
        // debounced write restamped a restored position on launch. It is in ``canCommitFold`` now,
        // so both paths are held to it — see ``PositionPublication``.
        guard canCommitFold, let item = foldItem else { return }
        let itemID = item.id

        // The main context, synchronously, and that is the whole reason this is not
        // ``writePosition()``. The debounced write hops to a background context, and a hop does
        // not come back from a process that is exiting — `willTerminate` and
        // `didEnterBackground` are the last moments this code is guaranteed to run.
        let deviceID = DeviceIdentity.current.id
        guard
            let wrote = try? PositionCommit.write(
                scope: scope,
                itemID: itemID,
                deviceID: deviceID,
                in: modelContext
            ),
            wrote
        else {
            return
        }
        lastWrittenFoldID = itemID
        save()

        // The badge otherwise only moves when a feed refresh happens to run — every fifteen
        // minutes by default — so reading a timeline empty would leave the old number on the icon
        // until then.
        services.positionSettled()
    }

    private static var leavingForegroundNotification: Notification.Name {
        #if os(macOS)
        NSApplication.willTerminateNotification
        #else
        UIApplication.didEnterBackgroundNotification
        #endif
    }

    /// Keeps the row under the reader where it is when items arrive above it.
    ///
    /// A scroll view preserves its content *offset*, so prepending twenty rows to a
    /// newest-first list pushes whatever the user was reading twenty rows down the screen. Pinning
    /// the anchor back to the top edge is the difference between auto-refresh being pleasant and
    /// being infuriating.
    ///
    /// ## The case that used to be excluded, and why it was the important one
    ///
    /// This began with `fold.id != previousNewest` in its guard, which skipped the reader who was
    /// caught up — the fold sitting on the newest row — even though the documentation claimed
    /// otherwise. That is not a corner: it is the state a reader is in every time they finish a
    /// scope, and it is the state a refresh most often lands in.
    ///
    /// Skipped, the list stayed at offset zero while the new items were inserted above it, so the
    /// reader was left looking at the top of the *new* items with the count reading zero. Then the
    /// fold was re-read from the screen, found row 0 again, and committed it — writing the newest
    /// arrival as the reading position and pushing it to every other device. Refreshing therefore
    /// marked everything it had just fetched as read, which is the one thing a reader with no
    /// read/unread state cannot recover from: there is no unread flag left to restore.
    ///
    /// Held, the same refresh leaves the previously-newest row exactly where it was on screen with
    /// the arrivals stacked above it and the count saying how many, which is what the position
    /// exists to do.
    private func holdScrollAnchor(previousCount: Int, proxy: ScrollViewProxy) {
        // Skip the first population, where there is nothing to protect and the restore is still
        // running.
        ScrollDiagnostics.shared.open("items \(previousCount) → \(items.count) in \(scope.rawValue)")
        guard previousCount > 0, hasRestored else {
            ScrollDiagnostics.shared.note("no hold — previousCount=\(previousCount) hasRestored=\(hasRestored)")
            return
        }
        guard let foldID = fold.itemID, let row = rowOfItem(foldID) else {
            ScrollDiagnostics.shared.note("no hold — fold=\(fold.itemID ?? "nil") is not in this scope")
            return
        }
        // Pinned against the **anchor**, not the fold. They are the same row in the ordinary case
        // and they part company in exactly the case that was reported: a second batch landing while
        // a hold from the first is still armed, with the reader scrolling through it. The fold is
        // frozen for the duration of a hold — deliberately, see `FoldState.anchorItemID` — so
        // arming from it pinned the reader back to where they had been rather than holding what was
        // on screen.
        let anchorID = fold.anchorItemID ?? foldID
        let anchorRow = rowOfItem(anchorID) ?? row
        ScrollDiagnostics.shared.note(String(
            format: "hold armed fold=row %d anchor=row %d offset=%.1f",
            row,
            anchorRow,
            fold.anchorOffset
        ))

        // ## Why this no longer scrolls
        //
        // It used to ask the `ScrollViewProxy` to put the held row back at the top edge, three
        // times over a fifth of a second. That worked and it was *visible*: the rows dropped by
        // the height of what arrived and snapped back a frame or two later, so every refresh
        // twitched. The three passes were themselves the tell — the first is issued from inside
        // the update that inserted the rows, before the backing table has them, so it lands on
        // nothing, and a proxy scroll cannot be made to happen any sooner than that.
        //
        // The row index below, though, is known *now*: it comes from the array the table is about
        // to be handed. So the correction is handed to the backing view, which applies it from its
        // own layout — in the same pass that brings the rows in, before anything is drawn. The
        // rows land already at the right offset instead of landing low and being scrolled back.
        // See `ScrollAnchor`.
        //
        // Held to the fold's recorded *offset* rather than to the top edge, because the fold row
        // sits a little below that edge by definition and pinning it flush reads as one row
        // further down — which the next commit would write down as a move nobody made.
        heldAnchorID = foldID
        heldAnchorAt = .now
        foldHandle.holdAnchor(row: anchorRow, offset: fold.anchorOffset, for: Self.anchorHoldWindow)

        anchorHold?.cancel()
        anchorHold = Task { @MainActor in
            // Insurance against a backing view that never reports its geometry changing. Each
            // pass is a no-op once the hold has landed, and the hold expires on its own.
            for _ in 0..<Self.anchorHoldPasses {
                guard heldAnchorID == foldID else { break }
                foldHandle.pinIfHolding()
                do { try await Task.sleep(for: Self.restoreSettleDelay) } catch { break }
                guard !Task.isCancelled else { break }
            }

            // Deliberately does not release the hold — ``isHoldReleased()`` does that, on evidence
            // from the screen, because this loop cannot tell whether the pin took.
            //
            // The count, though, comes from the table either way: the fold item has not moved but
            // its index has, and re-reading it from the geometry is what used to make the position
            // creep a row per refresh.
            //
            // Only while the fold is still the item that was held. It is, both when the pin
            // landed and while the hold is still armed — but not when the reader scrolled away
            // meanwhile, and there this would put the position back on a row they have left.
            guard fold.itemID == foldID else { return }
            guard let settled = rowOfItem(foldID) else { return }
            fold.row = settled
            counts.reportLiveCount(settled, for: scope)
        }

        // The row is taken from the **table**, not measured back off the screen, and that is the
        // second half of the fix. The fold item has not moved but its index has, so the count of
        // items above it has to be re-read — and reading it from the geometry reports whatever is
        // against the top edge, which lands a row out often enough to matter. The list already
        // knows the answer, so it says so; the restore learned the same lesson.
        fold.row = row
        // Reported so the sidebar and the "N newer" label account for what just arrived, rather
        // than continuing to show the count from before the refresh.
        counts.reportLiveCount(row, for: scope)
    }

    /// Where an item sits in the list, or nil when it is no longer in this scope.
    ///
    /// A linear scan, and affordable because it runs once per arrival of a new newest item rather
    /// than per body evaluation — which is the distinction that made ``item(withID:)`` a fetch.
    /// The stored position cannot answer this instead: the fold may not have been committed yet.
    private func rowOfItem(_ id: String) -> Int? {
        items.firstIndex { $0.id == id }
    }

    /// Persists and refreshes the counts.
    ///
    /// The counts observe `ModelContext.didSave`, so saving is what updates the sidebar and the
    /// menu's own label — there is no separate notification to remember to send.
    private func save() {
        try? modelContext.save()
    }
}
