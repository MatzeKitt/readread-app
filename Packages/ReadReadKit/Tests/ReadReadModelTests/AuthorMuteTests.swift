import Foundation
import SwiftData
import Testing

@testable import ReadReadModel

/// Clearing a muted account's posts out of the local store.
///
/// The half of muting that happens on this device, and the half that decides whether the action
/// looks like it worked: the instance stops *delivering* the person's posts, which does nothing
/// about the ones already fetched. What is worth pinning here is the reach of the sweep — too
/// narrow and the reader still sees them, too wide and it takes somebody else's posts with it.
@Suite("Author mute")
struct AuthorMuteTests {

    private let accountA = UUID()
    private let accountB = UUID()

    private func makeContext() throws -> ModelContext {
        ModelContext(try ReadReadStore.inMemoryContainer())
    }

    @discardableResult
    private func insert(
        id: String,
        accountID: UUID,
        handle: String?,
        kind: ItemKind = .status,
        in context: ModelContext
    ) -> CachedItem {
        let key = SortKey(millis: 1_700_000_000_000, id: id)
        let item = CachedItem(
            id: id,
            sourceID: "home",
            accountID: accountID,
            kind: kind,
            title: "Post \(id)",
            publishedAt: Date(millisecondsSinceEpoch: 1_700_000_000_000),
            sortKey: key,
            ingestKey: key
        )
        item.authorHandle = handle
        context.insert(item)
        return item
    }

    private func remaining(in context: ModelContext) throws -> [String] {
        try context.fetch(FetchDescriptor<CachedItem>()).map(\.id).sorted()
    }

    @Test("Muting removes that account's posts")
    func removesTheAuthorsPosts() throws {
        let context = try makeContext()
        insert(id: "1", accountID: accountA, handle: "noisy@example.social", in: context)
        insert(id: "2", accountID: accountA, handle: "noisy@example.social", in: context)
        insert(id: "3", accountID: accountA, handle: "someone@example.social", in: context)

        let removed = try AuthorMute.removeItems(
            byAuthorHandle: "noisy@example.social",
            accountID: accountA,
            in: context
        )

        #expect(removed == 2)
        #expect(try remaining(in: context) == ["3"])
    }

    /// A mute is a statement to one instance about one reader's timeline, not a global block. The
    /// same person followed from a second account keeps appearing there until that account mutes
    /// them too — anything else would be this app inventing a mute the servers do not have.
    @Test("A mute on one account leaves the other account's copy alone")
    func doesNotReachAcrossAccounts() throws {
        let context = try makeContext()
        insert(id: "a", accountID: accountA, handle: "noisy@example.social", in: context)
        insert(id: "b", accountID: accountB, handle: "noisy@example.social", in: context)

        let removed = try AuthorMute.removeItems(
            byAuthorHandle: "noisy@example.social",
            accountID: accountA,
            in: context
        )

        #expect(removed == 1)
        #expect(try remaining(in: context) == ["b"])
    }

    /// An article has an author name too, and a feed whose byline happened to match a handle would
    /// otherwise lose its articles to a Mastodon mute.
    @Test("Articles are never touched")
    func leavesArticlesAlone() throws {
        let context = try makeContext()
        insert(id: "post", accountID: accountA, handle: "noisy@example.social", in: context)
        insert(id: "article", accountID: accountA, handle: "noisy@example.social", kind: .article, in: context)

        let removed = try AuthorMute.removeItems(
            byAuthorHandle: "noisy@example.social",
            accountID: accountA,
            in: context
        )

        #expect(removed == 1)
        #expect(try remaining(in: context) == ["article"])
    }

    /// The handle arrives from a menu title in one place and from a decoded payload in another, and
    /// only one of those has an `@` on the front.
    @Test("A leading at-sign makes no difference", arguments: ["noisy@example.social", "@noisy@example.social", "  @noisy@example.social "])
    func toleratesTheAtSign(input: String) throws {
        let context = try makeContext()
        insert(id: "1", accountID: accountA, handle: "noisy@example.social", in: context)

        #expect(try AuthorMute.removeItems(byAuthorHandle: input, accountID: accountA, in: context) == 1)
    }

    /// "Everything with no handle recorded" is not a person, and deleting the lot would empty a
    /// store written before the column existed.
    @Test("An empty handle removes nothing")
    func emptyHandleIsNotAWildcard() throws {
        let context = try makeContext()
        insert(id: "1", accountID: accountA, handle: nil, in: context)
        insert(id: "2", accountID: accountA, handle: "", in: context)

        #expect(try AuthorMute.removeItems(byAuthorHandle: "", accountID: accountA, in: context) == 0)
        #expect(try AuthorMute.removeItems(byAuthorHandle: "  @ ", accountID: accountA, in: context) == 0)
        #expect(try remaining(in: context) == ["1", "2"])
    }

    /// Nothing to report is not a failure, and the caller uses the count to know whether to say so.
    @Test("Muting someone with nothing in the list removes nothing")
    func mutingSomebodyAbsentIsHarmless() throws {
        let context = try makeContext()
        insert(id: "1", accountID: accountA, handle: "someone@example.social", in: context)

        #expect(try AuthorMute.removeItems(byAuthorHandle: "nobody@example.social", accountID: accountA, in: context) == 0)
        #expect(try remaining(in: context) == ["1"])
    }
}
