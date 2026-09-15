import Foundation
import ReadReadSupport
import SwiftData

/// Re-applies the filter rules to everything already in the cache.
///
/// Needed because filtering is decided at **ingest** — `CachedItem.isFilteredOut` is a stored
/// column so that timeline queries and every sidebar count can exclude hidden items inside their
/// predicate. That is what makes the counts cheap, and the price is that editing a rule leaves the
/// whole store stale until it is walked again.
///
/// A `@ModelActor` so the walk happens off the main context. Editing a rule with a large cache
/// touches every row, and doing that on the main context would freeze the window mid-edit — which,
/// since the filter editor shows a live match count, is exactly when the user is watching.
@ModelActor
public actor FilterReevaluator {

    /// What one pass changed.
    public struct Outcome: Sendable, Equatable {
        /// Items that became hidden.
        public var hidden: Int
        /// Items that became visible again.
        public var revealed: Int
        /// Items examined.
        public var examined: Int

        public var changed: Int { hidden + revealed }

        public init(hidden: Int = 0, revealed: Int = 0, examined: Int = 0) {
            self.hidden = hidden
            self.revealed = revealed
            self.examined = examined
        }
    }

    /// How many items are loaded at a time.
    ///
    /// Batched rather than fetched whole because a cache is tens of thousands of items each
    /// carrying its full article HTML, and faulting all of that in at once is hundreds of megabytes
    /// for a pass that only needs to look at each row once.
    private static let batchSize = 500

    /// Stripped article bodies from previous preview passes, by item id.
    private var strippedBodies: [String: String] = [:]

    private var strippedCharacters = 0

    /// How much stripped text to keep, in characters.
    ///
    /// Thirty-two million, which is tens of megabytes and covers a couple of thousand full-text
    /// articles — a whole ordinary cache, and the tail of an unusually fat one.
    ///
    /// Two mistakes to avoid, in opposite directions. Too small and every pass still pays full
    /// price for whatever did not fit: the first number tried here was 8 million, which held four
    /// hundred of two thousand articles and saved a fifth of a pass nobody would have noticed. Too
    /// large and a filter editor costs more memory than the timeline it filters, on a phone, for a
    /// sheet somebody opened to type six characters.
    ///
    /// Past the budget the remaining items strip on every pass. Nothing is evicted, and the walk
    /// visits items in a stable order, so it is always the same tail — a partial saving rather than
    /// a cache that thrashes.
    private static let strippedCharacterBudget = 32_000_000

    /// Rebuilds the engine from the stored rules and applies it to every cached item.
    ///
    /// Returns what changed, so the caller can decide whether the counts need refreshing at all.
    @discardableResult
    public func reapplyAll() throws -> Outcome {
        let rules = try modelContext.fetch(FetchDescriptor<FilterRule>())
        return try reapply(FilterEngine(rules))
    }

    @discardableResult
    public func reapply(_ engine: FilterEngine) throws -> Outcome {
        let titles = try sourceTitles()
        var outcome = Outcome()
        var offset = 0

        while true {
            var descriptor = FetchDescriptor<CachedItem>(
                sortBy: [SortDescriptor(\.id, order: .forward)]
            )
            descriptor.fetchOffset = offset
            descriptor.fetchLimit = Self.batchSize
            // The body is only faulted in when a rule actually reads it. Without this every pass
            // would drag every article's HTML through memory even for a title-only rule set.
            descriptor.propertiesToFetch = engine.inspectsContent
                ? []
                : [\.id, \.title, \.authorName, \.accountID, \.sourceID, \.isFilteredOut]

            let batch = try modelContext.fetch(descriptor)
            guard !batch.isEmpty else { break }

            for item in batch {
                outcome.examined += 1
                let hidden = engine.hides(subject(for: item, titles: titles, engine: engine))
                guard hidden != item.isFilteredOut else { continue }

                item.isFilteredOut = hidden
                if hidden { outcome.hidden += 1 } else { outcome.revealed += 1 }
            }

            // Saved per batch, so an interrupted pass leaves a store that is partly re-evaluated
            // rather than one that has done all the work and persisted none of it. Filtering is
            // idempotent, so the next pass simply finishes the job.
            try modelContext.save()

            // Paged by offset over a stable sort on `id`. Safe here in a way it would not be for a
            // sort on a column this loop mutates: `isFilteredOut` changes under the walk, and
            // paging over an ordering that depends on it would skip rows.
            offset += batch.count
        }

        return outcome
    }

    /// Counts how many cached items a rule set would hide, without changing anything.
    ///
    /// Drives the filter editor's live "hides N items" preview, which is the only honest way to
    /// tell whether a pattern does what you meant before committing it.
    ///
    /// ## What makes this affordable to run while someone types
    ///
    /// It is the same walk as ``reapply(_:)`` but it happens *repeatedly* — once after every pause
    /// in typing — so the three costs a single pass can absorb are the three that had to go:
    ///
    /// - **Faulting the bodies.** This used to fetch whole rows, so a title-only rule still dragged
    ///   every article's HTML through memory. `propertiesToFetch` now leaves the body behind and it
    ///   is read only where a rule actually needs it, which for a cache of a few thousand articles
    ///   is the difference between hundreds of megabytes and a narrow column scan.
    /// - **Stripping them.** `HTMLText.plainText(from:)` over the whole cache dominates everything
    ///   else put together, and its result cannot change between passes — only the pattern does. So
    ///   it is kept, and the second and later passes skip it entirely. Which is why the caller holds
    ///   one of these actors for as long as the editor is open rather than making a fresh one per
    ///   keystroke; a new actor starts cold and the saving never happens.
    /// - **Finishing work nobody is waiting for.** Cancellation was checked once per 500-item batch,
    ///   and with stripping in the loop a batch is long enough that a superseded pass kept a core
    ///   busy well into the next keystroke. It is now checked as the walk goes.
    ///
    /// Measured against a deliberately unkind store — two thousand articles of twenty kilobytes of
    /// full text each, a rule reading title and text — a pass went from **11.0 s every time** to
    /// 6.9 s for the first and 1.7–5.8 s after, the spread being how early in a body the pattern
    /// turns up. A title-only rule over the same store is 0.16 s, which is what the walk costs when
    /// no body is touched at all. The remaining seconds are two things this does not address: a
    /// case-insensitive substring search over tens of megabytes, and `HTMLText.plainText(from:)`
    /// walking `String` a character at a time. If the preview ever needs to be faster than this, the
    /// lever with no downside left in it is examining only the newest few thousand items — which
    /// changes what the number means, and so is a decision rather than an optimisation.
    public func matchCount(for engine: FilterEngine, limit: Int? = nil) throws -> Int {
        let titles = try sourceTitles()
        var matches = 0
        var offset = 0

        while true {
            var descriptor = FetchDescriptor<CachedItem>(
                sortBy: [SortDescriptor(\.id, order: .forward)]
            )
            descriptor.fetchOffset = offset
            descriptor.fetchLimit = Self.batchSize
            // The body is deliberately not in this list even when a rule reads it: what a rule
            // needs is the *stripped* text, and anything already stripped once is served from
            // `strippedBodies` without the row's HTML being faulted at all.
            descriptor.propertiesToFetch = [
                \.id, \.title, \.authorName, \.accountID, \.sourceID, \.isFilteredOut,
            ]

            let batch = try modelContext.fetch(descriptor)
            guard !batch.isEmpty else { break }

            for item in batch {
                // Inside the loop, not once per batch. See the note above.
                try Task.checkCancellation()

                guard engine.hides(previewSubject(for: item, titles: titles, engine: engine)) else {
                    continue
                }
                matches += 1
                if let limit, matches >= limit { return matches }
            }

            offset += batch.count
        }

        return matches
    }

    /// A subject whose body text comes from the strip cache, filling it on the way.
    ///
    /// Built field by field rather than through ``subject(for:titles:engine:)``, and that is the
    /// whole trick: that one reads `item.contentHTML` for any content-reading rule set, which
    /// faults the body in from SQLite *before* anything gets to say it already has the text. Going
    /// through it made the cache free of charge and worthless — measured at 9.7 seconds warm
    /// against 11.0 cold over two thousand articles, which is to say no saving at all.
    private func previewSubject(
        for item: CachedItem,
        titles: [String: String],
        engine: FilterEngine
    ) -> FilterSubject {
        var subject = FilterSubject(
            title: item.title,
            authorName: item.authorName,
            sourceTitle: titles[item.sourceID],
            accountID: item.accountID,
            sourceID: item.sourceID,
            // Left empty on purpose. Reading the real body here is the expensive thing being
            // avoided, and `contentText` below is what the engine will use instead.
            contentHTML: ""
        )
        guard engine.inspectsContent else { return subject }

        if let cached = strippedBodies[item.id] {
            subject.contentText = cached
            return subject
        }

        // The one place the body is touched, and therefore the one place it is faulted in.
        let text = HTMLText.plainText(from: item.contentHTML)
        subject.contentText = text
        remember(text, for: item.id)
        return subject
    }

    /// Keeps a stripped body for the next pass, within ``strippedCharacterBudget``.
    ///
    /// Bounded by characters rather than by entry count, because item bodies differ by two orders
    /// of magnitude and a count would bound nothing in particular.
    private func remember(_ text: String, for id: String) {
        guard strippedCharacters + text.count <= Self.strippedCharacterBudget else { return }
        strippedBodies[id] = text
        strippedCharacters += text.count
    }

    /// Builds a subject, leaving the body out when no rule reads it.
    ///
    /// This is the other half of `propertiesToFetch`: the descriptor only avoids loading article
    /// HTML if nothing then goes and reads it back off the model, which would fault the row in
    /// anyway and make the whole optimisation a no-op.
    private func subject(
        for item: CachedItem,
        titles: [String: String],
        engine: FilterEngine
    ) -> FilterSubject {
        FilterSubject(
            title: item.title,
            authorName: item.authorName,
            sourceTitle: titles[item.sourceID],
            accountID: item.accountID,
            sourceID: item.sourceID,
            contentHTML: engine.inspectsContent ? item.contentHTML : ""
        )
    }

    private func sourceTitles() throws -> [String: String] {
        let sources = try modelContext.fetch(FetchDescriptor<CachedSource>())
        return Dictionary(sources.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
    }
}
