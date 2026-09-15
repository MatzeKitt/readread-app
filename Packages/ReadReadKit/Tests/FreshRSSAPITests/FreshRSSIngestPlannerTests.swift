import Foundation
import ReadReadModel
import ReadReadSupport
import ReadReadTestSupport
import Testing

@testable import FreshRSSAPI

/// These are the tests the sectioned-ingest design exists for.
///
/// Every failure mode here is one that cannot be reproduced on demand against a live server, is
/// silent when it happens, and loses items permanently — a stop line that advances too early, a
/// resumed walk that starts in the wrong place, a page committed without its cursor.
@Suite("FreshRSS sectioned ingest")
struct FreshRSSIngestPlannerTests {

    private let accountID = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!

    private let loginBody = "SID=matze/tok\nAuth=matze/tok"

    // MARK: - Page scripting

    /// Builds a `stream/contents` page whose ids descend from `startID`.
    ///
    /// Ids descend because FreshRSS entry ids are insertion timestamps and the stream is ordered
    /// by id descending — the fixture has to share that property or the walk under test is not
    /// being exercised faithfully.
    private func page(startID: UInt64, count: Int, continuation: String?) -> StubTransport.Response {
        let items = (0..<count).map { offset -> String in
            let id = startID - UInt64(offset)
            let published = 1_700_000_000 + Int(id % 100_000)
            return """
            {
                "id": "tag:google.com,2005:reader/item/\(String(format: "%016llx", id))",
                "crawlTimeMsec": "\(id / 1_000)",
                "published": \(published),
                "title": "Item \(id)",
                "canonical": [{ "href": "https://example.com/\(id)" }],
                "origin": { "streamId": "feed/1", "title": "Feed One" },
                "summary": { "content": "<p>Body of \(id).</p>" }
            }
            """
        }
        let continuationField = continuation.map { ",\n\"continuation\": \"\($0)\"" } ?? ""
        return .json("""
        { "items": [\(items.joined(separator: ","))]\(continuationField) }
        """)
    }

    private func makePlanner(
        _ transport: StubTransport,
        sink: RecordingIngestSink,
        pageSize: Int = 3
    ) -> FreshRSSIngestPlanner {
        let client = GReaderClient(
            baseURL: URL(string: "https://rss.example.net")!,
            credentials: .init(username: "matze", apiPassword: "p"),
            http: HTTPClient(transport: transport, policy: RetryPolicy(maxAttempts: 1), clock: TestClock())
        )
        return FreshRSSIngestPlanner(client: client, sink: sink, accountID: accountID, pageSize: pageSize)
    }

    // MARK: - Basic walk

    @Test("A first ingest walks to the end of the stream and promotes the stop line")
    func firstIngestWalksToEnd() async throws {
        let transport = StubTransport([
            .text(loginBody),
            page(startID: 1_000, count: 3, continuation: "997"),
            page(startID: 997, count: 3, continuation: "994"),
            page(startID: 994, count: 2, continuation: nil),
        ])
        let sink = RecordingIngestSink(accountID: accountID)
        let planner = makePlanner(transport, sink: sink)

        let outcome = try await planner.ingest()

        #expect(outcome.isComplete)
        #expect(outcome.pagesFetched == 3)
        #expect(outcome.itemsWritten == 8)
        #expect(await sink.itemCount == 8)
        // The stop line becomes the highest id seen, which is the newest item in the stream.
        #expect(await sink.state(accountID: accountID).highestSeenID == "1000")
        #expect(await sink.state(accountID: accountID).isWalkInProgress == false)
    }

    @Test("The walk stops at the first already-known id")
    func stopsAtKnownID() async throws {
        let transport = StubTransport([
            .text(loginBody),
            // 1000, 999, 998 are new; 997 is the stop line and must end the walk.
            page(startID: 1_000, count: 4, continuation: "996"),
        ])
        let sink = RecordingIngestSink(
            initialState: IngestCursorState(highestSeenID: "997"),
            accountID: accountID
        )
        let planner = makePlanner(transport, sink: sink, pageSize: 4)

        let outcome = try await planner.ingest()

        #expect(outcome.isComplete)
        #expect(outcome.pagesFetched == 1)
        #expect(outcome.itemsWritten == 3)
        // Only one page was needed even though a continuation was offered: descending order means
        // everything past the stop line is already known.
        #expect(await transport.requestCount == 2)
    }

    @Test("Nothing new means no items written and the stop line unchanged")
    func nothingNewWritesNothing() async throws {
        let transport = StubTransport([
            .text(loginBody),
            page(startID: 1_000, count: 3, continuation: "997"),
        ])
        let sink = RecordingIngestSink(
            initialState: IngestCursorState(highestSeenID: "1000"),
            accountID: accountID
        )
        let planner = makePlanner(transport, sink: sink)

        let outcome = try await planner.ingest()

        #expect(outcome.isComplete)
        #expect(outcome.itemsWritten == 0)
        #expect(await sink.state(accountID: accountID).highestSeenID == "1000")
    }

    @Test("An empty stream completes cleanly")
    func emptyStreamCompletes() async throws {
        let transport = StubTransport([.text(loginBody), .json(#"{"items":[]}"#)])
        let sink = RecordingIngestSink(accountID: accountID)
        let planner = makePlanner(transport, sink: sink)

        let outcome = try await planner.ingest()

        #expect(outcome.isComplete)
        #expect(outcome.itemsWritten == 0)
        // With nothing ever seen there is no stop line to set, and an empty one must not be
        // mistaken for a real cursor later.
        #expect(await sink.state(accountID: accountID).highestSeenID.isEmpty)
    }

    // MARK: - The two-cursor guarantee

    /// The central claim of the design. If this fails, items are lost silently.
    @Test("The stop line does not move when a run is cut short")
    func stopLineDoesNotMoveOnInterruptedRun() async throws {
        let transport = StubTransport([
            .text(loginBody),
            page(startID: 1_000, count: 3, continuation: "997"),
            page(startID: 997, count: 3, continuation: "994"),
        ])
        let sink = RecordingIngestSink(accountID: accountID)
        let planner = makePlanner(transport, sink: sink)

        let outcome = try await planner.ingest(budget: IngestBudget(maxPages: 2))

        #expect(outcome.isComplete == false)
        #expect(outcome.stoppedForBudget)
        #expect(await sink.abandonments == 1)

        let state = await sink.state(accountID: accountID)
        // Still empty. Had this been promoted to 1000, the next run would stop instantly at the
        // top of the stream and everything below page 2 would never be fetched.
        #expect(state.highestSeenID.isEmpty)
        #expect(state.isWalkInProgress)
        #expect(state.resumeContinuation == "994")
        #expect(state.pendingHighestSeenID == "1000")
    }

    /// The property that actually matters: an interrupted-then-resumed run has to be
    /// indistinguishable in outcome from one that ran straight through.
    @Test("An interrupted run resumes and yields exactly the same items as an uninterrupted one")
    func resumedRunMatchesUninterruptedRun() async throws {
        // Uninterrupted, in one go.
        let straightThrough = StubTransport([
            .text(loginBody),
            page(startID: 1_000, count: 3, continuation: "997"),
            page(startID: 997, count: 3, continuation: "994"),
            page(startID: 994, count: 3, continuation: "991"),
            page(startID: 991, count: 2, continuation: nil),
        ])
        let referenceSink = RecordingIngestSink(accountID: accountID)
        _ = try await makePlanner(straightThrough, sink: referenceSink).ingest()
        let expected = await referenceSink.committedIDs

        // Interrupted after two pages, then resumed twice.
        let resumedSink = RecordingIngestSink(accountID: accountID)

        let firstLeg = StubTransport([
            .text(loginBody),
            page(startID: 1_000, count: 3, continuation: "997"),
            page(startID: 997, count: 3, continuation: "994"),
        ])
        let first = try await makePlanner(firstLeg, sink: resumedSink).ingest(budget: IngestBudget(maxPages: 2))
        #expect(first.isComplete == false)

        // The resumed walk must ask the server to continue from exactly where it stopped.
        let secondLeg = StubTransport([
            .text(loginBody),
            page(startID: 994, count: 3, continuation: "991"),
            page(startID: 991, count: 2, continuation: nil),
        ])
        let second = try await makePlanner(secondLeg, sink: resumedSink).ingest()
        #expect(second.isComplete)
        #expect(await secondLeg.queryItems(at: 1)["c"] == "994")

        #expect(await resumedSink.committedIDs == expected)
        #expect(await resumedSink.itemCount == 11)
        // And only now does the stop line advance, to the newest item of the whole walk.
        #expect(await resumedSink.state(accountID: accountID).highestSeenID == "1000")
    }

    /// The gap this guards against: an interrupted run saw item 1000 but never fetched the pages
    /// below. If the stop line had been promoted, those would be unreachable forever.
    @Test("Items below an interrupted run's high-water mark are still fetched afterwards")
    func gapBelowInterruptedRunIsStillFetched() async throws {
        let sink = RecordingIngestSink(accountID: accountID)

        let firstLeg = StubTransport([.text(loginBody), page(startID: 1_000, count: 3, continuation: "997")])
        _ = try await makePlanner(firstLeg, sink: sink).ingest(budget: IngestBudget(maxPages: 1))
        #expect(await sink.itemCount == 3)

        let secondLeg = StubTransport([.text(loginBody), page(startID: 997, count: 3, continuation: nil)])
        _ = try await makePlanner(secondLeg, sink: sink).ingest()

        let ids = await sink.committedIDs
        #expect(ids.count == 6)
        // 997, 996 and 995 sit below the first run's high-water mark of 1000 and were still
        // retrieved.
        #expect(ids.contains { $0.hasSuffix("00000000000003e5") })
    }

    /// A stale resume cursor left over from a completed run would start the next walk part-way
    /// down the stream, silently skipping everything newer than that point.
    @Test("A resume cursor from a completed run is ignored")
    func staleResumeCursorIsIgnored() async throws {
        let transport = StubTransport([.text(loginBody), page(startID: 1_000, count: 2, continuation: nil)])
        let sink = RecordingIngestSink(
            initialState: IngestCursorState(
                highestSeenID: "500",
                resumeContinuation: "600",
                isWalkInProgress: false,
                pendingHighestSeenID: "700"
            ),
            accountID: accountID
        )
        let planner = makePlanner(transport, sink: sink)

        _ = try await planner.ingest()

        // No `c` parameter: the walk must start at the top of the stream, not at 600.
        #expect(await transport.queryItems(at: 1)["c"] == nil)
    }

    @Test("Every page commits its items together with its resume cursor")
    func eachPageCommitsCursorWithItems() async throws {
        let transport = StubTransport([
            .text(loginBody),
            page(startID: 1_000, count: 3, continuation: "997"),
            page(startID: 997, count: 3, continuation: "994"),
            page(startID: 994, count: 1, continuation: nil),
        ])
        let sink = RecordingIngestSink(accountID: accountID)
        let planner = makePlanner(transport, sink: sink)

        _ = try await planner.ingest()

        let commits = await sink.commits
        #expect(commits.count == 3)
        // Cursor and items advance in lockstep. Committing one without the other means either
        // duplicated or skipped items after a crash.
        #expect(commits[0].resumeContinuation == "997")
        #expect(commits[1].resumeContinuation == "994")
        #expect(commits[2].resumeContinuation == "")
        #expect(commits.allSatisfy { $0.pendingHighestSeenID == "1000" })
    }

    // MARK: - Budget

    @Test("The time budget stops the run between pages, not mid-page")
    func timeBudgetStopsBetweenPages() async throws {
        let transport = StubTransport([
            .text(loginBody),
            page(startID: 1_000, count: 3, continuation: "997"),
            page(startID: 997, count: 3, continuation: "994"),
        ], fallback: page(startID: 1, count: 1, continuation: nil))

        let sink = RecordingIngestSink(accountID: accountID)
        let planner = makePlanner(transport, sink: sink)

        // Expires after two pages have been fetched.
        let counter = PageCounter()
        let budget = IngestBudget(maxPages: 100) { counter.value < 2 }

        let outcome = try await planner.ingest(budget: budget)
        await counter.noop()

        #expect(outcome.stoppedForBudget)
        #expect(outcome.isComplete == false)
        // Exactly two whole pages. A partially committed page would leave the cursor describing
        // work that was not actually done, so the count must land on a page boundary *and* be the
        // page count actually fetched.
        #expect(outcome.pagesFetched == 2)
        #expect(outcome.itemsWritten == 6)
        #expect(await sink.state(accountID: accountID).highestSeenID.isEmpty)
    }

    /// Counts `hasTimeRemaining` calls, which the planner makes once per page.
    private final class PageCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int {
            lock.withLock {
                defer { count += 1 }
                return count
            }
        }
        func noop() async {}
    }

    @Test("A page budget of zero does no work and abandons the run")
    func zeroPageBudgetDoesNothing() async throws {
        let transport = StubTransport([])
        let sink = RecordingIngestSink(accountID: accountID)
        let planner = makePlanner(transport, sink: sink)

        let outcome = try await planner.ingest(budget: IngestBudget(maxPages: 0))

        #expect(outcome.pagesFetched == 0)
        #expect(outcome.isComplete == false)
        #expect(await transport.requestCount == 0)
        #expect(await sink.abandonments == 1)
    }

    @Test("Cancellation propagates instead of being swallowed")
    func cancellationPropagates() async throws {
        let transport = StubTransport([], fallback: page(startID: 1_000, count: 3, continuation: "997"))
        let sink = RecordingIngestSink(accountID: accountID)
        let planner = makePlanner(transport, sink: sink)

        let task = Task { try await planner.ingest(budget: IngestBudget(maxPages: 1_000)) }
        task.cancel()

        await #expect(throws: (any Error).self) { try await task.value }
    }

    // MARK: - Mapping

    @Test("Items map onto the store's shape")
    func mapsItemFields() async throws {
        let transport = StubTransport([.text(loginBody), page(startID: 1_000, count: 1, continuation: nil)])
        let sink = RecordingIngestSink(accountID: accountID)
        let planner = makePlanner(transport, sink: sink)

        _ = try await planner.ingest(folders: ["feed/1": "Apple"])

        let items = await sink.items
        let item = items.values.first!

        #expect(item.accountID == accountID)
        #expect(item.sourceID == SourceIdentifier.freshRSS(accountID: accountID, streamID: "feed/1"))
        #expect(item.folderName == "Apple")
        #expect(item.kind == .article)
        #expect(item.title == "Item 1000")
        #expect(item.urlString == "https://example.com/1000")
        #expect(item.providerID == "1000")
        // The excerpt is precomputed at ingest so the list never parses HTML while scrolling.
        #expect(item.excerpt == "Body of 1000.")
    }

    /// Ordering follows the server's fetch time, not the date the feed claims. A publisher-supplied
    /// date is not trustworthy enough to sort by — this account had one five days in the future —
    /// but it is still what the row displays, so both have to survive ingest.
    @Test("A back-dated item sorts by when it was fetched, and still shows its own date")
    func sortsByFetchTimeAndKeepsPublishedDate() async throws {
        let json = """
        { "items": [{
            "id": "tag:google.com,2005:reader/item/00000000000003e8",
            "crawlTimeMsec": "1756999000000",
            "published": 1600000000,
            "title": "Back-dated",
            "origin": { "streamId": "feed/1" },
            "summary": { "content": "<p>x</p>" }
        }] }
        """
        let transport = StubTransport([.text(loginBody), .json(json)])
        let sink = RecordingIngestSink(accountID: accountID)
        let planner = makePlanner(transport, sink: sink)

        _ = try await planner.ingest()

        let item = await sink.items.values.first!
        // Sorted where the server put it, which is the top of the reading list.
        #expect(item.sortKey.millis == 1_756_999_000_000)
        #expect(item.ingestKey.millis == 1_756_999_000_000)
        // The feed's own date is untouched, because that is what the reader is shown.
        #expect(item.publishedAt == Date(millisecondsSinceEpoch: 1_600_000_000_000))
    }

    /// The failure that forced the change, as a test: a publisher dating an item into the future.
    @Test("A future-dated item does not sort above everything fetched after it")
    func futureDatedItemDoesNotPinToTheTop() async throws {
        let json = """
        { "items": [
            {
                "id": "tag:google.com,2005:reader/item/00000000000003e8",
                "crawlTimeMsec": "1756999000000",
                "published": 4000000000,
                "title": "Dated next week",
                "origin": { "streamId": "feed/1" },
                "summary": { "content": "<p>x</p>" }
            },
            {
                "id": "tag:google.com,2005:reader/item/00000000000003e9",
                "crawlTimeMsec": "1756999100000",
                "published": 1756999100,
                "title": "Fetched afterwards",
                "origin": { "streamId": "feed/1" },
                "summary": { "content": "<p>y</p>" }
            }
        ] }
        """
        let transport = StubTransport([.text(loginBody), .json(json)])
        let sink = RecordingIngestSink(accountID: accountID)
        let planner = makePlanner(transport, sink: sink)

        _ = try await planner.ingest()

        let items = await sink.items.values.sorted { $0.sortKey > $1.sortKey }
        #expect(items.map(\.title) == ["Fetched afterwards", "Dated next week"])
    }

    @Test("An item missing a published date falls back to its insertion time")
    func missingPublishedFallsBackToIngest() async throws {
        let json = """
        { "items": [{
            "id": "tag:google.com,2005:reader/item/00000000000003e8",
            "crawlTimeMsec": "1756999000000",
            "origin": { "streamId": "feed/1" }
        }] }
        """
        let transport = StubTransport([.text(loginBody), .json(json)])
        let sink = RecordingIngestSink(accountID: accountID)
        let planner = makePlanner(transport, sink: sink)

        _ = try await planner.ingest()

        let item = await sink.items.values.first!
        // Falls back to server insertion time, never to local wall time — which would differ
        // between devices and make one device's ordering disagree with another's.
        #expect(item.sortKey.millis == 1_756_999_000_000)
    }

    @Test("Enclosures become attachments, and unusable ones are dropped")
    func mapsEnclosures() async throws {
        let json = """
        { "items": [{
            "id": "tag:google.com,2005:reader/item/00000000000003e8",
            "crawlTimeMsec": "1000",
            "origin": { "streamId": "feed/1" },
            "enclosure": [
                { "href": "https://example.com/a.mp3", "type": "audio/mpeg", "length": 42 },
                { "href": "https://example.com/b.png", "type": "image/png" },
                { "type": "image/png" }
            ]
        }] }
        """
        let transport = StubTransport([.text(loginBody), .json(json)])
        let sink = RecordingIngestSink(accountID: accountID)
        let planner = makePlanner(transport, sink: sink)

        _ = try await planner.ingest()

        let attachments = await sink.items.values.first!.attachments
        // The third has no href and is unusable, so it is dropped rather than stored as a broken
        // row the detail view would later try to load.
        #expect(attachments.count == 2)
        #expect(attachments[0].kind == .audio)
        #expect(attachments[0].byteCount == 42)
        #expect(attachments[1].kind == .image)
    }

    // MARK: - Subscriptions

    @Test("Subscriptions become sources and yield a folder map")
    func refreshesSubscriptions() async throws {
        let json = """
        {"subscriptions":[
            {"id":"feed/1","title":"One","categories":[{"id":"user/-/label/Apple","label":"Apple"}],
             "htmlUrl":"https://one.example","iconUrl":"https://one.example/icon.png"},
            {"id":"feed/2","title":"Two","categories":[],"htmlUrl":"","iconUrl":""}
        ]}
        """
        let transport = StubTransport([.text(loginBody), .json(json)])
        let sink = RecordingIngestSink(accountID: accountID)
        let planner = makePlanner(transport, sink: sink)

        let folders = try await planner.refreshSubscriptions()

        #expect(folders["feed/1"] == "Apple")
        #expect(folders["feed/2"] == String?.none)

        let sources = await sink.sources
        #expect(sources.count == 2)
        #expect(sources[0].id == SourceIdentifier.freshRSS(accountID: accountID, streamID: "feed/1"))
        #expect(sources[0].folderName == "Apple")
        #expect(sources[0].iconURLString == "https://one.example/icon.png")
        // Order from the server is preserved rather than re-sorted alphabetically.
        #expect(sources[0].sortIndex == 0)
        #expect(sources[1].sortIndex == 1)
        #expect(sources[1].iconURLString == nil)
    }
}
