import Foundation
import ReadReadModel
import ReadReadSupport
import ReadReadTestSupport
import Testing

@testable import MastodonAPI

/// Mastodon has no server-side date bound — `timelines/home` takes only id cursors — so the window
/// is applied to what comes back, and the walk has to stop rather than page on into the archive.
@Suite("Mastodon history window")
struct MastodonHistoryWindowTests {

    private let accountID = UUID()

    /// A whole status, because `MastodonStatus` decodes strictly and a window test that fails on a
    /// missing `visibility` tells you nothing about windows.
    private func status(id: String, daysAgo: Double, now: Date) -> String {
        let stamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-daysAgo * 86_400))
        return """
        {
            "id": "\(id)",
            "uri": "https://m.example/users/a/statuses/\(id)",
            "created_at": "\(stamp)",
            "content": "<p>Post \(id).</p>",
            "visibility": "public",
            "sensitive": false,
            "spoiler_text": "",
            "media_attachments": [],
            "reblog": null,
            "in_reply_to_id": null,
            "in_reply_to_account_id": null,
            "url": "https://m.example/@a/\(id)",
            "poll": null,
            "card": null,
            "emojis": [],
            "tags": [],
            "mentions": [],
            "replies_count": 0,
            "reblogs_count": 0,
            "favourites_count": 0,
            "edited_at": null,
            "language": "en",
            "account": {
                "id": "1",
                "username": "a",
                "acct": "a@m.example",
                "display_name": "Author A",
                "avatar": "https://files.example/a.png",
                "avatar_static": "https://files.example/a.png",
                "url": "https://m.example/@a",
                "bot": false,
                "emojis": []
            }
        }
        """
    }

    @Test("The walk stops at the window instead of paging on into the archive")
    func stopsAtTheWindow() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let page = """
        [\(status(id: "300", daysAgo: 1, now: now)),
         \(status(id: "200", daysAgo: 3, now: now)),
         \(status(id: "100", daysAgo: 40, now: now))]
        """

        let transport = StubTransport([.json(page)])
        let client = MastodonClient(
            instanceURL: URL(string: "https://m.example")!,
            accessToken: "token",
            http: HTTPClient(transport: transport, policy: RetryPolicy(maxAttempts: 1), clock: TestClock())
        )
        let sink = RecordingIngestSink()
        let planner = MastodonIngestPlanner(client: client, sink: sink, accountID: accountID)

        let outcome = try await planner.ingest(historyWindowDays: 7, now: now)

        // The forty-day-old post is past the window, so it is not written — and because the
        // timeline is time-ordered, the run is finished rather than merely interrupted.
        #expect(outcome.itemsWritten == 2)
        #expect(outcome.isComplete)
        #expect(await sink.itemCount == 2)
    }

    @Test("With no window the same page is taken whole")
    func unlimitedTakesEverything() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let page = """
        [\(status(id: "300", daysAgo: 1, now: now)),
         \(status(id: "100", daysAgo: 40, now: now))]
        """

        let transport = StubTransport([.json(page)])
        let client = MastodonClient(
            instanceURL: URL(string: "https://m.example")!,
            accessToken: "token",
            http: HTTPClient(transport: transport, policy: RetryPolicy(maxAttempts: 1), clock: TestClock())
        )
        let sink = RecordingIngestSink()
        let planner = MastodonIngestPlanner(client: client, sink: sink, accountID: accountID)

        _ = try await planner.ingest(historyWindowDays: HistoryWindow.unlimited, now: now)
        #expect(await sink.itemCount == 2)
    }
}
