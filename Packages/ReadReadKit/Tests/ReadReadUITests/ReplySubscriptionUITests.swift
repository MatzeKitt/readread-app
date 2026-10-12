import Foundation
import MastodonAPI
import ReadReadModel
import Testing

@testable import ReadReadUI

/// Where reply subscriptions appear in the sidebar.
@Suite("Reply subscriptions in the sidebar")
struct ReplySubscriptionSidebarTests {

    private let account = AccountRecord(
        id: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!,
        kind: .mastodon,
        displayName: "@matze@mastodon.social",
        serverURLString: "https://mastodon.social",
        username: "matze"
    )

    private var home: CachedSource {
        CachedSource(
            id: SourceIdentifier.mastodonHome(accountID: account.id),
            accountID: account.id,
            kind: .status,
            title: "Home"
        )
    }

    private func subscription(_ title: String, createdAt: TimeInterval, accountID: UUID? = nil) -> ReplySubscription {
        ReplySubscription(
            accountID: accountID ?? account.id,
            statusID: "\(Int(createdAt))",
            statusURLString: "https://mastodon.social/@matze/\(Int(createdAt))",
            title: title,
            createdAt: Date(timeIntervalSince1970: createdAt)
        )
    }

    @Test("A subscription is listed under its account, after the home timeline, oldest first")
    func listedUnderAccount() throws {
        let newer = subscription("Newer", createdAt: 200)
        let older = subscription("Older", createdAt: 100)
        let elsewhere = subscription("Other account", createdAt: 50, accountID: UUID())

        let sections = SidebarTree.build(
            accounts: [account],
            sources: [home],
            replySubscriptions: [newer, elsewhere, older]
        )
        let rows = try #require(sections.first { $0.title == account.displayName }).rows

        #expect(rows.map(\.title) == ["Home", "Older", "Newer"])
        #expect(rows[1].scope == .replySubscription(older.id))
        #expect(rows[1].children.isEmpty)
    }

    @Test("A subscription without a title is shown by its link")
    func untitledShowsLink() throws {
        let untitled = subscription("", createdAt: 100)

        let sections = SidebarTree.build(accounts: [account], sources: [home], replySubscriptions: [untitled])
        let rows = try #require(sections.first { $0.title == account.displayName }).rows

        #expect(rows.last?.title == untitled.statusURLString)
    }
}

/// How far each reply in a whole conversation is set in.
@Suite("Conversation depth")
struct ConversationDepthTests {

    private func status(_ id: String, replyingTo parent: String?) throws -> MastodonStatus {
        let body = """
        {"id":"\(id)","uri":"https://example.social/users/x/statuses/\(id)",
         "created_at":"2026-09-01T09:00:00.000Z",
         "account":{"id":"7","username":"x","acct":"x",
                    "display_name":"X","avatar":"https://x/a.png","url":"https://example.social/@x","emojis":[]},
         "content":"<p>Hello.</p>","visibility":"public","sensitive":false,"spoiler_text":"",
         "in_reply_to_id":\(parent.map { "\"\($0)\"" } ?? "null"),
         "media_attachments":[],"emojis":[],"tags":[],"mentions":[],
         "replies_count":0,"reblogs_count":0,"favourites_count":0}
        """
        return try JSONDecoder.mastodon.decode(MastodonStatus.self, from: Data(body.utf8))
    }

    @Test("Depth follows the chain of replies up to the subscribed post")
    func followsChain() throws {
        let depths = StatusThreadLoader.depths(of: [
            try status("2", replyingTo: "1"),
            try status("3", replyingTo: "2"),
            try status("4", replyingTo: "3"),
            try status("5", replyingTo: "1"),
        ], under: "1")

        #expect(depths == ["2": 1, "3": 2, "4": 3, "5": 1])
    }

    /// The instance withholds some replies — from blocked accounts, or ones it has not fetched —
    /// and their answers then name a parent that is not in the list.
    @Test("A reply whose parent is missing sits directly under the post")
    func missingParent() throws {
        let depths = StatusThreadLoader.depths(of: [
            try status("2", replyingTo: "1"),
            try status("4", replyingTo: "3"),
        ], under: "1")

        #expect(depths["4"] == 1)
    }

    @Test("A malformed cycle ends instead of hanging")
    func cycleEnds() throws {
        let depths = StatusThreadLoader.depths(of: [
            try status("2", replyingTo: "3"),
            try status("3", replyingTo: "2"),
        ], under: "1")

        #expect(depths.count == 2)
    }
}
