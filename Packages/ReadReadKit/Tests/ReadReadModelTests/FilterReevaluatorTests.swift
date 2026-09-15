import Foundation
import SwiftData
import Testing

@testable import ReadReadModel

/// Against a real store, because the pass is as much about how it walks SwiftData — batching,
/// paging, what it faults in — as it is about the matching, and the matching is covered separately.
@Suite("FilterReevaluator")
struct FilterReevaluatorTests {

    private let accountID = UUID()

    private func makeContainer() throws -> ModelContainer {
        try ReadReadStore.inMemoryContainer()
    }

    private func insertItems(
        _ titles: [String],
        sourceID: String = "feed/1",
        contentHTML: String = "",
        in context: ModelContext
    ) {
        for (offset, title) in titles.enumerated() {
            let millis = 1_700_000_000_000 + Int64(offset) * 1_000
            let key = SortKey(millis: millis, id: "\(sourceID)#\(offset)")
            context.insert(CachedItem(
                id: "\(sourceID)#\(offset)",
                sourceID: sourceID,
                accountID: accountID,
                kind: .article,
                title: title,
                contentHTML: contentHTML,
                publishedAt: Date(millisecondsSinceEpoch: millis),
                sortKey: key,
                ingestKey: key
            ))
        }
    }

    private func hiddenCount(in container: ModelContainer) throws -> Int {
        let context = ModelContext(container)
        return try context.fetchCount(
            FetchDescriptor<CachedItem>(predicate: #Predicate { $0.isFilteredOut })
        )
    }

    @Test("A new rule hides the items already in the cache")
    func hidesExistingItems() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        insertItems(["Crypto is back", "A fine widget", "Crypto again"], in: context)
        try context.save()

        let engine = FilterEngine([FilterRule(pattern: "crypto", fields: .title)])
        let outcome = try await FilterReevaluator(modelContainer: container).reapply(engine)

        #expect(outcome.hidden == 2)
        #expect(outcome.revealed == 0)
        #expect(outcome.examined == 3)
        #expect(try hiddenCount(in: container) == 2)
    }

    @Test("Removing a rule brings its items back")
    func revealsWhenRuleGoes() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        insertItems(["Crypto is back", "A fine widget"], in: context)
        try context.save()

        let reevaluator = FilterReevaluator(modelContainer: container)
        _ = try await reevaluator.reapply(FilterEngine([FilterRule(pattern: "crypto", fields: .title)]))
        #expect(try hiddenCount(in: container) == 1)

        // The half that is easy to forget: `isFilteredOut` is stored, so deleting a rule does
        // nothing at all until the store is walked again.
        let outcome = try await reevaluator.reapply(FilterEngine([]))
        #expect(outcome.revealed == 1)
        #expect(try hiddenCount(in: container) == 0)
    }

    @Test("Running the same pass twice changes nothing the second time")
    func isIdempotent() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        insertItems(["Crypto is back", "A fine widget"], in: context)
        try context.save()

        let reevaluator = FilterReevaluator(modelContainer: container)
        let engine = FilterEngine([FilterRule(pattern: "crypto", fields: .title)])

        _ = try await reevaluator.reapply(engine)
        let second = try await reevaluator.reapply(engine)

        // Matters because a pass is saved per batch and may be interrupted: the next one has to be
        // able to finish the job without undoing any of it.
        #expect(second.changed == 0)
        #expect(second.examined == 2)
    }

    @Test("The pass covers more items than fit in one batch")
    func pagesThroughEverything() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        // Deliberately past the 500-item batch size, so a paging bug shows up as a short count
        // rather than passing by accident.
        insertItems((0..<1_200).map { "Item \($0) crypto" }, in: context)
        try context.save()

        let outcome = try await FilterReevaluator(modelContainer: container)
            .reapply(FilterEngine([FilterRule(pattern: "crypto", fields: .title)]))

        #expect(outcome.examined == 1_200)
        #expect(outcome.hidden == 1_200)
    }

    @Test("A content rule reads the body, which a title-only rule never faults in")
    func contentRulesReachTheBody() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        insertItems(["Innocuous"], contentHTML: "<p>all about crypto</p>", in: context)
        try context.save()

        let reevaluator = FilterReevaluator(modelContainer: container)

        _ = try await reevaluator.reapply(FilterEngine([FilterRule(pattern: "crypto", fields: .title)]))
        #expect(try hiddenCount(in: container) == 0)

        _ = try await reevaluator.reapply(FilterEngine([FilterRule(pattern: "crypto", fields: .content)]))
        #expect(try hiddenCount(in: container) == 1)
    }

    @Test("The source name is matched against the source's own title")
    func sourceTitlesAreResolved() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        context.insert(CachedSource(
            id: "feed/1",
            accountID: accountID,
            kind: .article,
            title: "Daily Tabloid"
        ))
        insertItems(["Anything"], in: context)
        try context.save()

        let outcome = try await FilterReevaluator(modelContainer: container)
            .reapply(FilterEngine([FilterRule(pattern: "Tabloid", fields: .sourceTitle)]))

        #expect(outcome.hidden == 1)
    }

    @Test("The preview counts without changing anything")
    func matchCountIsReadOnly() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        insertItems(["Crypto is back", "A fine widget", "More crypto"], in: context)
        try context.save()

        let reevaluator = FilterReevaluator(modelContainer: container)
        let engine = FilterEngine([FilterRule(pattern: "crypto", fields: .title)])

        #expect(try await reevaluator.matchCount(for: engine) == 2)
        // The editor previews as the user types, long before Save — a preview that hid items would
        // filter the timeline against a half-typed pattern.
        #expect(try hiddenCount(in: container) == 0)
    }

    @Test("The preview stops counting at its limit")
    func matchCountRespectsLimit() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        insertItems((0..<50).map { "Item \($0) crypto" }, in: context)
        try context.save()

        let count = try await FilterReevaluator(modelContainer: container)
            .matchCount(for: FilterEngine([FilterRule(pattern: "crypto", fields: .title)]), limit: 10)

        #expect(count == 10)
    }
}

/// The preview's own behaviour, which is the part that runs while someone types.
///
/// The count is now served partly from a cache of stripped article bodies held on the actor between
/// passes, which is what makes typing a pattern affordable. Caching the *input* to matching while
/// the *pattern* changes underneath it is exactly the kind of optimisation that can start returning
/// last keystroke's answer, so the property tested here is that it does not: the same store and the
/// same rule give the same number cold and warm, and a new pattern is answered by the new pattern.
@Suite("Filter preview counting")
struct FilterPreviewCountTests {

    private let accountID = UUID()

    private func makeStore(_ bodies: [String]) throws -> ModelContainer {
        let container = try ReadReadStore.inMemoryContainer()
        let context = ModelContext(container)
        for (offset, body) in bodies.enumerated() {
            let millis = 1_700_000_000_000 + Int64(offset) * 1_000
            let key = SortKey(millis: millis, id: "feed/1#\(offset)")
            context.insert(CachedItem(
                id: "feed/1#\(offset)",
                sourceID: "feed/1",
                accountID: accountID,
                kind: .article,
                title: "Item \(offset)",
                contentHTML: "<p>\(body)</p>",
                publishedAt: Date(millisecondsSinceEpoch: millis),
                sortKey: key,
                ingestKey: key
            ))
        }
        try context.save()
        return container
    }

    private func engine(_ pattern: String) -> FilterEngine {
        FilterEngine([FilterRule(pattern: pattern, fields: .content)])
    }

    @Test("Counting the same rule twice gives the same answer")
    func warmCacheAgreesWithCold() async throws {
        let container = try makeStore(["about otters", "about badgers", "otters again"])
        let counter = FilterReevaluator(modelContainer: container)

        let cold = try await counter.matchCount(for: engine("otters"))
        let warm = try await counter.matchCount(for: engine("otters"))

        #expect(cold == 2)
        #expect(warm == cold)
    }

    /// The keystroke case. Between these two passes the bodies are cached and the pattern is not,
    /// which is the whole point: the second answer must be about the second pattern.
    @Test("A changed pattern is counted against the changed pattern")
    func changedPatternIsRecounted() async throws {
        let container = try makeStore(["about otters", "about badgers", "otters again"])
        let counter = FilterReevaluator(modelContainer: container)

        _ = try await counter.matchCount(for: engine("otters"))

        #expect(try await counter.matchCount(for: engine("badgers")) == 1)
        #expect(try await counter.matchCount(for: engine("about")) == 2)
        #expect(try await counter.matchCount(for: engine("nothing here")) == 0)
    }

    /// The preview and the real pass must agree, cache or no cache — a preview that says "hides 2"
    /// and then hides 3 is worse than no preview.
    @Test("The preview agrees with the pass it is previewing")
    func previewAgreesWithReapply() async throws {
        let container = try makeStore(["about otters", "about badgers", "otters again"])
        let counter = FilterReevaluator(modelContainer: container)
        let rule = engine("otters")

        // Twice, so the second count is the cached path.
        _ = try await counter.matchCount(for: rule)
        let previewed = try await counter.matchCount(for: rule)
        let applied = try await FilterReevaluator(modelContainer: container).reapply(rule)

        #expect(previewed == applied.hidden)
    }

    /// Body text has to be stripped of its markup before matching, and a cached body has to be the
    /// stripped one — matching against raw HTML would hide items for words that only appear in tags.
    @Test("Markup is not matched against")
    func markupIsNotMatched() async throws {
        // Stored as `<p>a plain sentence</p>`, so the tag is the thing no rule should ever see.
        let container = try makeStore(["a plain sentence"])
        let counter = FilterReevaluator(modelContainer: container)

        #expect(try await counter.matchCount(for: engine("<p")) == 0)
        #expect(try await counter.matchCount(for: engine("plain")) == 1)
        // Again, from the cache.
        #expect(try await counter.matchCount(for: engine("<p")) == 0)
    }

    /// The rule the editor opens with looks in the title *and* the text, so the body is stripped
    /// for every item that the title does not already match.
    @Test("A title-and-text rule counts both")
    func titleAndContentCountsBoth() async throws {
        let container = try makeStore(["about otters", "about badgers"])
        let counter = FilterReevaluator(modelContainer: container)
        let both = FilterEngine([FilterRule(pattern: "Item 1", fields: .titleAndContent)])

        #expect(try await counter.matchCount(for: both) == 1)
        #expect(try await counter.matchCount(for: engine("otters")) == 1)
    }

    @Test("The limit stops the walk early")
    func limitStopsTheWalk() async throws {
        let container = try makeStore(Array(repeating: "about otters", count: 20))
        let counter = FilterReevaluator(modelContainer: container)

        #expect(try await counter.matchCount(for: engine("otters"), limit: 5) == 5)
    }
}
