import Foundation
import ReadReadModel
import ReadReadSupport
import ReadReadTestSupport
import SwiftData
import Testing

@testable import ReadReadSync

/// The mentions walk rides on the home walk, and must never be able to take it down. Every account
/// signed in before `read:notifications` fails it until the reader authorises again, so how that
/// failure is reported decides whether the badge and the backoff keep working in the meantime.
@Suite("Refresh engine mentions")
struct RefreshEngineMentionsTests {

    private let accountID = UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000002")!

    private final class ReportBox: @unchecked Sendable {
        var reports: [RefreshReport] = []
    }

    private func makeKeychain() -> KeychainStore {
        KeychainStore(
            service: "com.kittmedia.ReadRead.tests.\(UUID().uuidString)",
            prefersDataProtectionKeychain: false
        )
    }

    private func makeAccount(in context: ModelContext, keychain: KeychainStore) throws {
        context.insert(AccountRecord(
            id: accountID,
            kind: .mastodon,
            displayName: "Test Mastodon",
            serverURLString: "https://mastodon.social",
            username: "matze"
        ))
        try context.save()
        try keychain.setString("tok", for: .mastodonAccessToken, key: accountID.uuidString)
    }

    /// Recent, so the default history window cannot cut the walk off before it writes anything.
    private let recent = Date.now.addingTimeInterval(-3600).formatted(.iso8601)

    private func statusJSON(id: String, author: String) -> String {
        """
        {
            "id": "\(id)",
            "uri": "https://mastodon.social/users/\(author)/statuses/\(id)",
            "created_at": "\(recent)",
            "content": "<p>Post \(id).</p>",
            "visibility": "public",
            "sensitive": false,
            "spoiler_text": "",
            "media_attachments": [],
            "reblog": null,
            "in_reply_to_id": null,
            "in_reply_to_account_id": null,
            "url": "https://mastodon.social/@\(author)/\(id)",
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
                "username": "\(author)",
                "acct": "\(author)",
                "display_name": "",
                "avatar": "https://files.example/a.png",
                "avatar_static": "https://files.example/a.png",
                "url": "https://mastodon.social/@\(author)",
                "bot": false,
                "emojis": []
            }
        }
        """
    }

    private var homePage: StubTransport.Response {
        .json("[\(statusJSON(id: "300", author: "friend"))]")
    }

    private func run(
        notifications: StubTransport.Response
    ) async throws -> (report: RefreshReport, container: ModelContainer, thrown: (any Error)?) {
        let container = try ReadReadStore.inMemoryContainer()
        let keychain = makeKeychain()
        try makeAccount(in: ModelContext(container), keychain: keychain)

        let transport = StubTransport([homePage, notifications])
        let engine = RefreshEngine(
            container: container,
            connections: AccountConnections(
                keychain: keychain,
                http: HTTPClient(transport: transport, policy: RetryPolicy(maxAttempts: 1), clock: TestClock())
            ),
            // No sync token stored, so the sync half is a no-op and cannot reach a network.
            endpoint: SyncEndpoint(keychain: keychain),
            badge: BadgePublisher { _ in },
            retention: RetentionPolicy(itemsPerSource: 1000, maximumAge: 0)
        )
        let box = ReportBox()
        await engine.setReportHandler { box.reports.append($0) }

        var thrown: (any Error)?
        do {
            try await engine.perform(.mastodonFeeds, trigger: .manual)
        } catch {
            thrown = error
        }
        return (try #require(box.reports.last), container, thrown)
    }

    private func itemIDs(in container: ModelContainer) throws -> Set<String> {
        Set(try ModelContext(container).fetch(FetchDescriptor<CachedItem>()).map(\.id))
    }

    @Test("A mention from a stranger lands in the home timeline")
    func mentionLands() async throws {
        let notifications = StubTransport.Response.json("""
        [{"id": "900", "type": "mention", "created_at": "\(recent)",
          "status": \(statusJSON(id: "301", author: "stranger"))}]
        """)

        let (report, container, thrown) = try await run(notifications: notifications)

        #expect(thrown == nil)
        #expect(report.isComplete)
        #expect(report.itemsWritten == 2)
        #expect(report.failures.isEmpty)

        let mention = try #require(
            try ModelContext(container).fetch(FetchDescriptor<CachedItem>())
                .first { $0.id == SourceIdentifier.mastodonItem(accountID: accountID, statusID: "301") }
        )
        #expect(mention.sourceID == SourceIdentifier.mastodonHome(accountID: accountID))
    }

    /// A token from before the scope. The home timeline must still arrive, the badge must still be
    /// allowed to publish, and the backoff must not be triggered by something only the reader can
    /// fix — but the reader has to be told what to do.
    @Test("A token without the notifications scope keeps the home timeline and asks to reauthorise")
    func missingScopeIsReportedNotRetried() async throws {
        let (report, container, thrown) = try await run(notifications: .status(403))

        #expect(thrown == nil)
        #expect(report.isComplete)
        #expect(report.itemsWritten == 1)
        #expect(report.retryableFailures.isEmpty)
        #expect(report.failures.count == 1)
        #expect(report.failures.first?.contains("Test Mastodon") == true)
        #expect(report.failures.first?.contains("Reauthorise") == true)
        #expect(try itemIDs(in: container) == [SourceIdentifier.mastodonItem(accountID: accountID, statusID: "300")])
    }

    @Test("A mentions walk that fails keeps what the home walk wrote")
    func failedMentionsKeepHome() async throws {
        let (report, container, _) = try await run(notifications: .status(500))

        #expect(report.itemsWritten == 1)
        #expect(!report.isComplete)
        #expect(report.retryableFailures.count == 1)
        #expect(try itemIDs(in: container) == [SourceIdentifier.mastodonItem(accountID: accountID, statusID: "300")])
    }
}
