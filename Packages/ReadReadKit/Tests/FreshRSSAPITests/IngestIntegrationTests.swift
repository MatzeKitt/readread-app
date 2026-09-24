import Foundation
import ReadReadModel
import ReadReadSupport
import ReadReadTestSupport
import SwiftData
import Testing

@testable import FreshRSSAPI

/// End-to-end ingest against a real SwiftData store.
///
/// The planner tests use a stub sink to pin down the paging and cursor logic. These exist because a
/// stub cannot prove the *store* behaves the same way — that the unique constraint really upserts,
/// that the folder denormalisation really moves, that a marker really gets seeded.
@Suite("Ingest integration")
struct IngestIntegrationTests {

    private let accountID = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000001")!
    private let deviceID = "test-device"
    private let loginBody = "SID=matze/tok\nAuth=matze/tok"

    private func makeSink() throws -> (SwiftDataIngestSink, ModelContainer) {
        let container = try ReadReadStore.inMemoryContainer()
        return (SwiftDataIngestSink(modelContainer: container), container)
    }

    private func makePlanner(
        _ transport: StubTransport,
        sink: SwiftDataIngestSink,
        pageSize: Int = 3
    ) -> FreshRSSIngestPlanner {
        let client = GReaderClient(
            baseURL: URL(string: "https://rss.example.net")!,
            credentials: .init(username: "matze", apiPassword: "p"),
            http: HTTPClient(transport: transport, policy: RetryPolicy(maxAttempts: 1), clock: TestClock())
        )
        return FreshRSSIngestPlanner(client: client, sink: sink, accountID: accountID, pageSize: pageSize)
    }

    private func page(
        startID: UInt64,
        count: Int,
        continuation: String?,
        streamID: String = "feed/1",
        publishedBase: Int = 1_700_000_000
    ) -> StubTransport.Response {
        let items = (0..<count).map { offset -> String in
            let id = startID - UInt64(offset)
            return """
            {
                "id": "tag:google.com,2005:reader/item/\(String(format: "%016llx", id))",
                "crawlTimeMsec": "\(1_700_000_000_000 + Int(id))",
                "published": \(publishedBase + Int(id)),
                "title": "Item \(id)",
                "canonical": [{ "href": "https://example.com/\(id)" }],
                "origin": { "streamId": "\(streamID)" },
                "summary": { "content": "<p>Body of \(id).</p>" }
            }
            """
        }
        let continuationField = continuation.map { ",\n\"continuation\": \"\($0)\"" } ?? ""
        return .json("{ \"items\": [\(items.joined(separator: ","))]\(continuationField) }")
    }

    private func subscriptionsResponse(_ feeds: [(id: String, title: String, folder: String?)]) -> StubTransport.Response {
        let entries = feeds.map { feed in
            let categories = feed.folder.map { #"[{"id":"user/-/label/\#($0)","label":"\#($0)"}]"# } ?? "[]"
            return #"{"id":"\#(feed.id)","title":"\#(feed.title)","categories":\#(categories),"iconUrl":""}"#
        }
        return .json(#"{"subscriptions":[\#(entries.joined(separator: ","))]}"#)
    }

    private func items(in container: ModelContainer) throws -> [CachedItem] {
        try ModelContext(container).fetch(
            FetchDescriptor<CachedItem>(sortBy: [SortDescriptor(\.sortKeyRaw, order: .reverse)])
        )
    }

    // MARK: - Basic persistence

    @Test("A completed ingest persists items and the cursor")
    func completedIngestPersists() async throws {
        let (sink, container) = try makeSink()
        await sink.configure(deviceID: deviceID)
        let transport = StubTransport([
            .text(loginBody),
            page(startID: 1_000, count: 3, continuation: "997"),
            page(startID: 997, count: 2, continuation: nil),
        ])

        let outcome = try await makePlanner(transport, sink: sink).ingest()

        #expect(outcome.isComplete)
        #expect(try items(in: container).count == 5)

        let state = try await sink.cursorState(
            accountID: accountID,
            streamKey: FreshRSSIngestPlanner.readingListStreamKey
        )
        #expect(state.highestSeenID == "1000")
        #expect(state.isWalkInProgress == false)
        #expect(state.resumeContinuation.isEmpty)
    }

    /// The store-level counterpart of the planner's resumption test: proves the real cursor row
    /// survives across separate planner instances, which is what a relaunch actually looks like.
    @Test("An interrupted run resumes against the real store and loses nothing")
    func interruptedRunResumesAgainstStore() async throws {
        let (sink, container) = try makeSink()
        await sink.configure(deviceID: deviceID)

        let firstLeg = StubTransport([
            .text(loginBody),
            page(startID: 1_000, count: 3, continuation: "997"),
        ])
        let first = try await makePlanner(firstLeg, sink: sink).ingest(budget: IngestBudget(maxPages: 1))
        #expect(first.isComplete == false)

        // The stop line must still be empty, or the gap below page 1 is lost forever.
        var state = try await sink.cursorState(
            accountID: accountID,
            streamKey: FreshRSSIngestPlanner.readingListStreamKey
        )
        #expect(state.highestSeenID.isEmpty)
        #expect(state.resumeContinuation == "997")

        let secondLeg = StubTransport([
            .text(loginBody),
            page(startID: 997, count: 3, continuation: nil),
        ])
        let second = try await makePlanner(secondLeg, sink: sink).ingest()
        #expect(second.isComplete)
        #expect(await secondLeg.queryItems(at: 1)["c"] == "997")

        #expect(try items(in: container).count == 6)
        state = try await sink.cursorState(
            accountID: accountID,
            streamKey: FreshRSSIngestPlanner.readingListStreamKey
        )
        #expect(state.highestSeenID == "1000")
    }

    /// `#Unique` upserts, so re-ingesting the same page must not duplicate rows. Without this,
    /// every refresh would grow the store.
    @Test("Re-ingesting the same items updates rather than duplicating")
    func reingestDoesNotDuplicate() async throws {
        let (sink, container) = try makeSink()
        await sink.configure(deviceID: deviceID)

        for _ in 0..<3 {
            let transport = StubTransport([.text(loginBody), page(startID: 1_000, count: 3, continuation: nil)])
            // A fresh cursor each time would be the pathological case; here the cursor persists,
            // so the second and third runs find nothing new.
            _ = try await makePlanner(transport, sink: sink).ingest()
        }

        #expect(try items(in: container).count == 3)
    }

    // MARK: - Late arrivals

    /// Ordering by fetch time is what makes this case ordinary rather than a hazard: an item the
    /// server has only just added is new, whatever date the feed puts on it. Under the previous
    /// published-date ordering this same item sorted below the marker and had to be rescued by the
    /// late-arrival mechanism to be findable at all.
    @Test("A back-dated arrival counts as new and sorts to the top")
    func backDatedArrivalIsOrdinary() async throws {
        let (sink, container) = try makeSink()
        await sink.configure(deviceID: deviceID)

        // Ingest a normal page, then read to the very top.
        let firstTransport = StubTransport([.text(loginBody), page(startID: 1_000, count: 3, continuation: nil)])
        _ = try await makePlanner(firstTransport, sink: sink).ingest()

        let context = ModelContext(container)
        let newest = try items(in: container).first!
        try ThresholdService.setPosition(.all, to: newest.sortKey, deviceID: deviceID, in: context)
        try context.save()
        #expect(try ThresholdService.newerCount(for: .all, in: context) == 0)

        // Now a back-dated item arrives with a *higher* entry id — it is new to the server, but
        // published years earlier.
        let lateTransport = StubTransport([
            .text(loginBody),
            .json("""
            { "items": [{
                "id": "tag:google.com,2005:reader/item/00000000000007d0",
                "crawlTimeMsec": "1800000000000",
                "published": 1500000000,
                "title": "From the archive",
                "origin": { "streamId": "feed/1" },
                "summary": { "content": "<p>Old.</p>" }
            }] }
            """),
        ])
        let outcome = try await makePlanner(lateTransport, sink: sink).ingest()

        // Nothing to rescue: it sorts above the marker like any other new item.
        #expect(outcome.lateArrivals == 0)

        let verify = ModelContext(container)
        #expect(try ThresholdService.newerCount(for: .all, in: verify) == 1)
        #expect(try ThresholdService.lateArrivalCount(for: .all, in: verify) == 0)
        #expect(try items(in: container).first?.title == "From the archive")
    }

    /// The mechanism is not dead, only rarely reached. What still lands below a marker is an item
    /// the *server* dates as added before the reader got to where they are — an import, or a feed
    /// removed and re-added — which arrives with a new entry id and an old `date_added`.
    @Test("An item the server added below the marker is still flagged late")
    func itemAddedBelowTheMarkerIsFlagged() async throws {
        let (sink, container) = try makeSink()
        await sink.configure(deviceID: deviceID)

        let firstTransport = StubTransport([.text(loginBody), page(startID: 1_000, count: 3, continuation: nil)])
        _ = try await makePlanner(firstTransport, sink: sink).ingest()

        let context = ModelContext(container)
        let newest = try items(in: container).first!
        try ThresholdService.setPosition(.all, to: newest.sortKey, deviceID: deviceID, in: context)
        try context.save()
        #expect(try ThresholdService.newerCount(for: .all, in: context) == 0)

        // A higher entry id, so the walk reaches it, but a `crawlTimeMsec` below the marker's.
        let lateTransport = StubTransport([
            .text(loginBody),
            .json("""
            { "items": [{
                "id": "tag:google.com,2005:reader/item/00000000000007d0",
                "crawlTimeMsec": "1700000000500",
                "published": 1700000000,
                "title": "Added behind the fold",
                "origin": { "streamId": "feed/1" },
                "summary": { "content": "<p>Old.</p>" }
            }] }
            """),
        ])
        let outcome = try await makePlanner(lateTransport, sink: sink).ingest()

        #expect(outcome.lateArrivals == 1)

        let verify = ModelContext(container)
        // Stored and discoverable, but it does not inflate the count the badge shows.
        #expect(try ThresholdService.newerCount(for: .all, in: verify) == 0)
        #expect(try ThresholdService.lateArrivalCount(for: .all, in: verify) == 1)
        #expect(try items(in: container).last?.title == "Added behind the fold")
    }

    /// Catching up with another device is not the same as being late.
    ///
    /// Scroll to the top on the Mac and its marker jumps to the newest article it holds. The phone
    /// pulls that position and then, on its next walk, fetches the very articles the Mac read past
    /// — every one of them below the marker. Flagged, the phone announced a pile of "older items"
    /// for a backlog the reader had just finished on the other device. Nothing arrived late; one
    /// device was behind the other.
    @Test("Items landing under another device's marker are not flagged late")
    func arrivalsUnderAForeignMarkerAreNotFlagged() async throws {
        let (sink, container) = try makeSink()
        await sink.configure(deviceID: deviceID)

        let firstTransport = StubTransport([.text(loginBody), page(startID: 1_000, count: 3, continuation: nil)])
        _ = try await makePlanner(firstTransport, sink: sink).ingest()

        // The other device read to the top and said so. Identical to the marker in the test above
        // in every respect but who wrote it.
        let context = ModelContext(container)
        let newest = try items(in: container).first!
        try ThresholdService.setPosition(.all, to: newest.sortKey, deviceID: "the-mac", in: context)
        try context.save()
        #expect(try ThresholdService.newerCount(for: .all, in: context) == 0)

        let lateTransport = StubTransport([
            .text(loginBody),
            .json("""
            { "items": [{
                "id": "tag:google.com,2005:reader/item/00000000000007d0",
                "crawlTimeMsec": "1700000000500",
                "published": 1700000000,
                "title": "Read past on the other device",
                "origin": { "streamId": "feed/1" },
                "summary": { "content": "<p>Old.</p>" }
            }] }
            """),
        ])
        let outcome = try await makePlanner(lateTransport, sink: sink).ingest()

        #expect(outcome.lateArrivals == 0)

        let verify = ModelContext(container)
        // Still stored, still below the marker, still not counted as newer — it simply is not
        // announced as something that arrived late.
        #expect(try ThresholdService.lateArrivalCount(for: .all, in: verify) == 0)
        #expect(try ThresholdService.newerCount(for: .all, in: verify) == 0)
        #expect(try items(in: container).last?.title == "Read past on the other device")
    }

    @Test("An item arriving above the marker is not flagged late")
    func normalArrivalIsNotFlagged() async throws {
        let (sink, container) = try makeSink()
        await sink.configure(deviceID: deviceID)

        let firstTransport = StubTransport([.text(loginBody), page(startID: 1_000, count: 3, continuation: nil)])
        _ = try await makePlanner(firstTransport, sink: sink).ingest()

        let context = ModelContext(container)
        let newest = try items(in: container).first!
        try ThresholdService.setPosition(.all, to: newest.sortKey, deviceID: deviceID, in: context)
        try context.save()

        let laterTransport = StubTransport([
            .text(loginBody),
            page(startID: 2_000, count: 1, continuation: nil, publishedBase: 1_900_000_000),
        ])
        let outcome = try await makePlanner(laterTransport, sink: sink).ingest()

        #expect(outcome.lateArrivals == 0)
        let verify = ModelContext(container)
        #expect(try ThresholdService.newerCount(for: .all, in: verify) == 1)
        #expect(try ThresholdService.lateArrivalCount(for: .all, in: verify) == 0)
    }

    /// `arrivedLate` is a judgement made when an item first appeared. Recomputing it on re-ingest
    /// against a marker that has since moved past the item would silently clear the flag.
    @Test("Re-ingesting a late arrival keeps its flag")
    func reingestPreservesLateFlag() async throws {
        let (sink, container) = try makeSink()
        await sink.configure(deviceID: deviceID)

        let item = IngestedItem(
            id: "item-1",
            sourceID: "source-1",
            accountID: accountID,
            kind: .article,
            title: "Old",
            publishedAt: Date(millisecondsSinceEpoch: 1_500_000_000_000),
            sortKey: SortKey(millis: 1_500_000_000_000, id: "item-1"),
            ingestKey: SortKey(millis: 1_800_000_000_000, id: "item-1"),
            providerID: "1"
        )

        // A first walk has to have finished before anything can be "late": during the initial
        // backfill the walk is paging *down* through the backlog, and flagging that would call
        // every item a feed has ever published a late arrival.
        try await sink.completeRun(accountID: accountID, streamKey: "reading-list", highestSeenID: "9")

        // Mark the scope as fully read so the first commit sees it as late.
        let context = ModelContext(container)
        try ThresholdService.setPosition(
            .all,
            to: SortKey(millis: 1_700_000_000_000, id: "x"),
            deviceID: deviceID,
            in: context
        )
        try context.save()

        _ = try await sink.commit(
            items: [item],
            accountID: accountID,
            streamKey: "reading-list",
            resumeContinuation: "",
            pendingHighestSeenID: "1"
        )
        #expect(try ModelContext(container).fetch(
            FetchDescriptor<CachedItem>(predicate: #Predicate { $0.arrivedLate })
        ).count == 1)

        // Second commit with a corrected title; the flag must survive.
        var updated = item
        updated.title = "Old (corrected)"
        _ = try await sink.commit(
            items: [updated],
            accountID: accountID,
            streamKey: "reading-list",
            resumeContinuation: "",
            pendingHighestSeenID: "1"
        )

        let rows = try ModelContext(container).fetch(FetchDescriptor<CachedItem>())
        #expect(rows.count == 1)
        #expect(rows[0].title == "Old (corrected)")
        #expect(rows[0].arrivedLate)
    }

    // MARK: - Sources and folders

    @Test("Subscriptions upsert into sources")
    func subscriptionsUpsert() async throws {
        let (sink, container) = try makeSink()
        await sink.configure(deviceID: deviceID)
        let transport = StubTransport([
            .text(loginBody),
            subscriptionsResponse([
                (id: "feed/1", title: "One", folder: "Apple"),
                (id: "feed/2", title: "Two", folder: nil),
            ]),
        ])

        _ = try await makePlanner(transport, sink: sink).refreshSubscriptions()

        let sources = try ModelContext(container).fetch(
            FetchDescriptor<CachedSource>(sortBy: [SortDescriptor(\.sortIndex)])
        )
        #expect(sources.count == 2)
        #expect(sources[0].title == "One")
        #expect(sources[0].folderName == "Apple")
        #expect(sources[1].folderName == nil)
    }

    /// Items attributed to a folder, independent of any reading position.
    private func folderItemCount(_ folder: String, in context: ModelContext) throws -> Int {
        try context.fetchCount(
            FetchDescriptor<CachedItem>(predicate: #Predicate { $0.folderName == folder })
        )
    }

    /// The denormalisation hazard, end to end: without the item-level update the feed's existing
    /// items stay in the old folder's count while only new ones appear in the right place.
    @Test("Moving a feed between folders moves its already-ingested items")
    func movingFolderMovesExistingItems() async throws {
        let (sink, container) = try makeSink()
        await sink.configure(deviceID: deviceID)

        let setup = StubTransport([
            .text(loginBody),
            subscriptionsResponse([(id: "feed/1", title: "One", folder: "Apple")]),
        ])
        let folders = try await makePlanner(setup, sink: sink).refreshSubscriptions()

        let ingest = StubTransport([.text(loginBody), page(startID: 1_000, count: 3, continuation: nil)])
        _ = try await makePlanner(ingest, sink: sink).ingest(folders: folders)

        var context = ModelContext(container)
        // Counts are asserted through the items themselves rather than through the threshold,
        // because ingest seeds a marker for a folder on first sight and the count would be zero
        // whichever folder the items were in.
        #expect(try folderItemCount("Apple", in: context) == 3)

        // The user moves the feed to a different category in FreshRSS.
        let moved = StubTransport([
            .text(loginBody),
            subscriptionsResponse([(id: "feed/1", title: "One", folder: "Tech")]),
        ])
        _ = try await makePlanner(moved, sink: sink).refreshSubscriptions()

        context = ModelContext(container)
        #expect(try folderItemCount("Apple", in: context) == 0)
        #expect(try folderItemCount("Tech", in: context) == 3)
        // And the new folder is seeded on sight, so the moved backlog does not flood its count
        // while the feed itself still reads zero.
        #expect(try ThresholdService.newerCount(for: .folder("Tech"), in: context) == 0)
    }

    /// A short subscription list from a hiccuping server must not destroy items and reading
    /// positions, so sources are flagged rather than deleted.
    @Test("A source missing from the subscription list is flagged, not deleted")
    func vanishedSourceIsFlaggedNotDeleted() async throws {
        let (sink, container) = try makeSink()
        await sink.configure(deviceID: deviceID)

        let both = StubTransport([
            .text(loginBody),
            subscriptionsResponse([
                (id: "feed/1", title: "One", folder: nil),
                (id: "feed/2", title: "Two", folder: nil),
            ]),
        ])
        _ = try await makePlanner(both, sink: sink).refreshSubscriptions()

        let onlyOne = StubTransport([
            .text(loginBody),
            subscriptionsResponse([(id: "feed/1", title: "One", folder: nil)]),
        ])
        _ = try await makePlanner(onlyOne, sink: sink).refreshSubscriptions()

        let sources = try ModelContext(container).fetch(FetchDescriptor<CachedSource>())
        #expect(sources.count == 2)
        #expect(sources.first { $0.title == "Two" }?.isSubscribed == false)
        #expect(sources.first { $0.title == "One" }?.isSubscribed == true)
    }

    /// Subscribing to a feed should not dump its whole backlog above the threshold — the badge
    /// jumping by hundreds reads as a bug and buries whatever the user was reading.
    @Test("A newly added feed's backlog does not flood the count")
    func newFeedBacklogDoesNotFloodCount() async throws {
        let (sink, container) = try makeSink()
        await sink.configure(deviceID: deviceID)

        let setup = StubTransport([
            .text(loginBody),
            subscriptionsResponse([(id: "feed/1", title: "One", folder: nil)]),
        ])
        let folders = try await makePlanner(setup, sink: sink).refreshSubscriptions()

        let ingest = StubTransport([.text(loginBody), page(startID: 1_000, count: 3, continuation: nil)])
        _ = try await makePlanner(ingest, sink: sink).ingest(folders: folders)

        let context = ModelContext(container)
        let sourceID = SourceIdentifier.freshRSS(accountID: accountID, streamID: "feed/1")

        // Both assertions are needed. A zero source count alone would also be produced by the
        // items being attributed to some *other* source id, which would be a mapping bug rather
        // than successful seeding — so confirm the items exist and belong to this source first.
        #expect(try context.fetchCount(
            FetchDescriptor<CachedItem>(predicate: #Predicate { $0.sourceID == sourceID })
        ) == 3)
        // The feed's own marker was seeded at its newest item on first import, so its backlog
        // contributes nothing.
        #expect(try ThresholdService.newerCount(for: .source(sourceID), in: context) == 0)
        // And so does the unified timeline's. A feed reading zero while `All Items` reported the
        // same three items is the sidebar contradicting itself, and it left the badge — which
        // defaults to `All Items` — reporting a backlog that nothing was new in.
        #expect(try ThresholdService.newerCount(for: .all, in: context) == 0)
        // Seeding moves the position, not the items: the backlog is still there to be read.
        #expect(try ThresholdService.itemAtPosition(for: .all, in: context) != nil)
    }

    /// The hazard the `maySeedMarkers` gate exists for. Reduction breaks a generation tie by
    /// taking the *furthest* mark, so a marker seeded at the newest item beats a genuine position
    /// arriving from another device — silently discarding it. A second device must therefore not
    /// seed until it knows where it actually is.
    @Test("Seeding is withheld until the device knows its real positions")
    func seedingIsWithheldBeforeFirstSync() async throws {
        let (sink, container) = try makeSink()
        await sink.configure(deviceID: deviceID, maySeedMarkers: false)

        let ingest = StubTransport([.text(loginBody), page(startID: 1_000, count: 3, continuation: nil)])
        _ = try await makePlanner(ingest, sink: sink).ingest()

        let context = ModelContext(container)
        #expect(try items(in: container).count == 3)
        // No marker anywhere: the position this device is about to receive has to win.
        #expect(try context.fetchCount(FetchDescriptor<PositionMark>()) == 0)
        #expect(try ThresholdService.effectivePosition(for: .all, in: context).markSortKey == .distantPast)
    }

    /// A Mastodon home timeline is stored as an ordinary source but the sidebar addresses it by
    /// `.mastodonHome`. Seeding the `.source` scope instead would leave the timeline reading zero
    /// while the sidebar showed the whole backlog — two markers over one set of items.
    @Test("A Mastodon source is seeded under the scope the sidebar counts")
    func mastodonSourceIsSeededUnderItsSidebarScope() async throws {
        let (sink, container) = try makeSink()
        await sink.configure(deviceID: deviceID)

        let accountID = UUID()
        let sourceID = SourceIdentifier.mastodonHome(accountID: accountID)

        try await sink.upsertSources(
            [IngestedSource(
                id: sourceID,
                accountID: accountID,
                kind: .status,
                title: "mastodon.social",
                sortIndex: 0
            )],
            accountID: accountID
        )

        let key = SortKey(millis: 1_700_000_000_000, id: "s1")
        _ = try await sink.commit(
            items: [IngestedItem(
                id: SourceIdentifier.mastodonItem(accountID: accountID, statusID: "s1"),
                sourceID: sourceID,
                accountID: accountID,
                kind: .status,
                title: "A post",
                publishedAt: Date(millisecondsSinceEpoch: 1_700_000_000_000),
                sortKey: key,
                ingestKey: key,
                providerID: "s1"
            )],
            accountID: accountID,
            streamKey: "home",
            resumeContinuation: "",
            pendingHighestSeenID: "s1"
        )
        try await sink.completeRun(accountID: accountID, streamKey: "home", highestSeenID: "s1")

        let context = ModelContext(container)
        #expect(try ThresholdService.newerCount(for: .mastodonHome(accountID: accountID), in: context) == 0)
    }

    /// `loadsFullPageContent` and `loadsComments` are the app's, not the server's. Subscription
    /// refresh runs on a timer and rewrites every source row from the server's list, so a field the
    /// server knows nothing about is one careless `CachedSource(...)` away from being reset behind
    /// the user's back — silently, and only on feeds they had deliberately configured.
    @Test("A refresh does not reset a feed's own settings")
    func refreshPreservesFullPageSetting() async throws {
        let (sink, container) = try makeSink()
        await sink.configure(deviceID: deviceID)

        let accountID = UUID()
        let source = IngestedSource(
            id: "freshrss:\(accountID):feed/1",
            accountID: accountID,
            kind: .article,
            title: "A Feed",
            folderName: "News",
            sortIndex: 0
        )
        try await sink.upsertSources([source], accountID: accountID)

        let context = ModelContext(container)
        let stored = try #require(try context.fetch(FetchDescriptor<CachedSource>()).first)
        stored.loadsFullPageContent = true
        stored.loadsComments = true
        try context.save()

        // The same feed comes back from the server, renamed and moved, as a real refresh would.
        var moved = source
        moved.title = "A Renamed Feed"
        moved.folderName = "Tech"
        try await sink.upsertSources([moved], accountID: accountID)

        let after = try #require(try ModelContext(container).fetch(FetchDescriptor<CachedSource>()).first)
        #expect(after.title == "A Renamed Feed")
        #expect(after.folderName == "Tech")
        #expect(after.loadsFullPageContent)
        #expect(after.loadsComments)
    }

    // MARK: - Filtering seam

    @Test("The filter evaluator marks matching items as hidden at ingest")
    func filterEvaluatorHidesItems() async throws {
        let (sink, container) = try makeSink()
        // Stands in for the compiled filter rules that the filter layer will supply.
        await sink.configure(deviceID: deviceID) { $0.title.contains("999") }

        let transport = StubTransport([.text(loginBody), page(startID: 1_000, count: 3, continuation: nil)])
        _ = try await makePlanner(transport, sink: sink).ingest()

        let context = ModelContext(container)
        let hidden = try context.fetch(FetchDescriptor<CachedItem>(predicate: #Predicate { $0.isFilteredOut }))
        #expect(hidden.count == 1)
        #expect(hidden.first?.title == "Item 999")
        // Filtered items are stored but excluded from every count. Asserted against a marker at
        // `distantPast` rather than the scope's real one, which ingest has just seeded to the
        // newest item — leaving a correct count of zero that would prove nothing about filtering.
        #expect(try context.fetchCount(FetchDescriptor<CachedItem>(
            predicate: ScopeQuery.newerPredicate(for: .all, than: SortKey.distantPast.rawValue)!
        )) == 2)
    }
}

/// The initial backfill is not a stream of late arrivals.
///
/// A separate suite because it is about the *interaction* between two things that are each correct
/// alone: the marker is seeded at the newest item so a new account's backlog contributes zero, and
/// the walk then pages downwards through that backlog. Together, without a guard, every page after
/// the first arrives below the marker and is flagged — which is how "3 older items arrived" became
/// 5,611 against a real account.
@Suite("Backfill is not a late arrival")
struct BackfillLateArrivalTests {

    private let accountID = UUID()
    private let deviceID = "device-a"

    private func makeSink() throws -> (SwiftDataIngestSink, ModelContainer) {
        let container = try ModelContainer(
            for: CachedItem.self, CachedSource.self, PositionMark.self, ReadLaterEntry.self,
                FilterRule.self, AccountRecord.self, SyncCursor.self, PendingChange.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return (SwiftDataIngestSink(modelContainer: container), container)
    }

    private func page(_ range: Range<Int>, base: Int64) -> [IngestedItem] {
        range.map { offset in
            let millis = base + Int64(offset) * 1_000
            let id = "item-\(offset)"
            return IngestedItem(
                id: id,
                sourceID: "source-1",
                accountID: accountID,
                kind: .article,
                title: "Item \(offset)",
                publishedAt: Date(millisecondsSinceEpoch: millis),
                sortKey: SortKey(millis: millis, id: id),
                ingestKey: SortKey(millis: millis, id: id),
                providerID: String(offset)
            )
        }
    }

    @Test("Paging down through a backlog flags nothing, even once a marker exists")
    func backfillIsNotLate() async throws {
        let (sink, container) = try makeSink()
        await sink.configure(deviceID: deviceID)

        // Page one: the newest items. Seeding then puts the marker at the top of these, exactly as
        // a first refresh does.
        _ = try await sink.commit(
            items: page(90..<100, base: 1_700_000_000_000),
            accountID: accountID,
            streamKey: "reading-list",
            resumeContinuation: "c1",
            pendingHighestSeenID: "99"
        )

        let context = ModelContext(container)
        let newest = try #require(try ThresholdService.newestItem(for: .all, in: context))
        try ThresholdService.setPosition(.all, to: newest.sortKey, deviceID: deviceID, in: context)
        try context.save()

        // Page two: older items, which is the only direction the walk goes.
        _ = try await sink.commit(
            items: page(80..<90, base: 1_700_000_000_000),
            accountID: accountID,
            streamKey: "reading-list",
            resumeContinuation: "c2",
            pendingHighestSeenID: "99"
        )

        let flagged = try ModelContext(container).fetchCount(
            FetchDescriptor<CachedItem>(predicate: #Predicate { $0.arrivedLate })
        )
        #expect(flagged == 0)
    }

    /// The same trap as the initial backfill, sprung by a few days away from the app rather than
    /// by a new account: the walk cannot reach its stop line in one page, so it pages down through
    /// the gap over the refreshes that follow. Those pages are history the device had not fetched
    /// yet, and calling them late arrivals announced a week of reading as "older items".
    @Test("A walk paging down into the gap after a break flags nothing")
    func catchingUpIsNotLate() async throws {
        let (sink, container) = try makeSink()
        await sink.configure(deviceID: deviceID)

        // A settled device: one walk finished, and the reader is sitting at the top of it.
        _ = try await sink.commit(
            items: page(90..<100, base: 1_700_000_000_000),
            accountID: accountID,
            streamKey: "reading-list",
            resumeContinuation: "",
            pendingHighestSeenID: "99"
        )
        try await sink.completeRun(accountID: accountID, streamKey: "reading-list", highestSeenID: "99")

        let context = ModelContext(container)
        let newest = try #require(try ThresholdService.newestItem(for: .all, in: context))
        try ThresholdService.setPosition(.all, to: newest.sortKey, deviceID: deviceID, in: context)
        try context.save()

        // Days later. The first page of the new walk carries the newest items, which sit above the
        // marker; it does not reach the stop line, so the walk goes on.
        _ = try await sink.commit(
            items: page(100..<110, base: 1_700_000_000_000),
            accountID: accountID,
            streamKey: "reading-list",
            resumeContinuation: "c1",
            pendingHighestSeenID: "109"
        )

        // The continuation: the middle of the gap, every item of it below where the reader
        // stopped. Ten of these were flagged before, all of them for having been fetched late
        // rather than for having arrived late.
        _ = try await sink.commit(
            items: page(80..<90, base: 1_700_000_000_000),
            accountID: accountID,
            streamKey: "reading-list",
            resumeContinuation: "c2",
            pendingHighestSeenID: "109"
        )

        let flagged = try ModelContext(container).fetchCount(
            FetchDescriptor<CachedItem>(predicate: #Predicate { $0.arrivedLate })
        )
        #expect(flagged == 0)
    }

    @Test("Once the first walk has completed, a genuinely back-dated item is still flagged")
    func lateArrivalsStillWorkAfterwards() async throws {
        let (sink, container) = try makeSink()
        await sink.configure(deviceID: deviceID)

        _ = try await sink.commit(
            items: page(90..<100, base: 1_700_000_000_000),
            accountID: accountID,
            streamKey: "reading-list",
            resumeContinuation: "",
            pendingHighestSeenID: "99"
        )
        try await sink.completeRun(accountID: accountID, streamKey: "reading-list", highestSeenID: "99")

        let context = ModelContext(container)
        let newest = try #require(try ThresholdService.newestItem(for: .all, in: context))
        try ThresholdService.setPosition(.all, to: newest.sortKey, deviceID: deviceID, in: context)
        try context.save()

        // A feed backfilling its archive after the walk has settled: this *is* a late arrival.
        _ = try await sink.commit(
            items: page(0..<1, base: 1_500_000_000_000),
            accountID: accountID,
            streamKey: "reading-list",
            resumeContinuation: "",
            pendingHighestSeenID: "99"
        )

        let flagged = try ModelContext(container).fetchCount(
            FetchDescriptor<CachedItem>(predicate: #Predicate { $0.arrivedLate })
        )
        #expect(flagged == 1)
    }
}

/// The history window has to bound the walk *and* survive being changed.
@Suite("History window at ingest")
struct HistoryWindowIngestTests {

    private let accountID = UUID()
    private let loginBody = "SID=x\nAuth=user/token"

    private func makeClient(_ transport: StubTransport) -> GReaderClient {
        GReaderClient(
            baseURL: URL(string: "https://rss.example.net")!,
            credentials: .init(username: "u", apiPassword: "p"),
            http: HTTPClient(transport: transport, policy: RetryPolicy(maxAttempts: 1), clock: TestClock())
        )
    }

    private let emptyPage = #"{"id":"reading-list","items":[],"continuation":null}"#

    /// One item at decimal id 200 — comfortably below a stop line of 500.
    private let oneOldItem = """
    {"id":"reading-list","items":[
      {"id":"tag:google.com,2005:reader/item/00000000000000c8","published":1699000000,
       "crawlTimeMsec":"1699000000000","title":"Older","origin":{"streamId":"feed/1"}}
    ],"continuation":null}
    """

    @Test("The window is sent to the server as an `ot` bound")
    func windowBecomesAnOTParameter() async throws {
        let transport = StubTransport([.text(loginBody), .json(emptyPage)])
        let planner = FreshRSSIngestPlanner(
            client: makeClient(transport),
            sink: RecordingIngestSink(),
            accountID: accountID
        )

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try await planner.ingest(historyWindowDays: 7, now: now)

        let urls = await transport.urls
        let stream = try #require(urls.last)
        // Seven days before `now`, in whole seconds, exactly as the endpoint expects.
        #expect(stream.contains("ot=\(Int(1_700_000_000 - 7 * 86_400))"))
    }

    @Test("No window means no bound is sent at all")
    func unlimitedSendsNoBound() async throws {
        let transport = StubTransport([.text(loginBody), .json(emptyPage)])
        let planner = FreshRSSIngestPlanner(
            client: makeClient(transport),
            sink: RecordingIngestSink(),
            accountID: accountID
        )

        _ = try await planner.ingest(historyWindowDays: HistoryWindow.unlimited)

        let urls = await transport.urls
        #expect(!(try #require(urls.last)).contains("ot="))
    }

    /// The bug this exists for: the walk stops at the first id it already knows, and FreshRSS ids
    /// are insertion timestamps — so an article published *and* inserted five weeks ago sits below
    /// the stop line permanently. Widening the window would fetch nothing and look broken.
    @Test("Widening the window discards the stop line for one run")
    func wideningRewalks() async throws {
        let sink = RecordingIngestSink(
            initialState: IngestCursorState(highestSeenID: "500", historyWindowDays: 7),
            accountID: accountID
        )
        let transport = StubTransport([.text(loginBody), .json(oneOldItem)])
        let planner = FreshRSSIngestPlanner(client: makeClient(transport), sink: sink, accountID: accountID)

        let outcome = try await planner.ingest(historyWindowDays: 30)

        #expect(outcome.itemsWritten == 1)
        #expect(outcome.isComplete)

        // And the new window is recorded, so the *next* run stops normally again.
        #expect(await sink.state(accountID: accountID).historyWindowDays == 30)
    }

    @Test("An unchanged window keeps the stop line, so a refresh stays incremental")
    func unchangedWindowStopsNormally() async throws {
        let sink = RecordingIngestSink(
            initialState: IngestCursorState(highestSeenID: "500", historyWindowDays: 7),
            accountID: accountID
        )
        let transport = StubTransport([.text(loginBody), .json(oneOldItem)])
        let planner = FreshRSSIngestPlanner(client: makeClient(transport), sink: sink, accountID: accountID)

        let outcome = try await planner.ingest(historyWindowDays: 7)

        // Item 200 is below the stop line of 500, so the walk stops without writing it.
        #expect(outcome.itemsWritten == 0)
        #expect(outcome.isComplete)
    }
}
