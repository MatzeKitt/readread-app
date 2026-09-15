import Foundation
import MastodonAPI
import ReadReadModel
import ReadReadSupport
import Testing

@testable import ReadReadSync

/// The two decisions in `StatusInteractions` that are not a network call: what gets written back
/// onto a row, and what a failure is allowed to say.
@Suite("Status interactions")
struct StatusInteractionTests {

    private func post() -> CachedItem {
        let key = SortKey(millis: 1_700_000_000_000, id: "s")
        return CachedItem(
            id: "s",
            sourceID: "mastodon:acct:home",
            accountID: UUID(),
            kind: .status,
            title: "A post.",
            publishedAt: .now,
            sortKey: key,
            ingestKey: key,
            replyCount: 1,
            reblogCount: 2,
            favouriteCount: 3,
            isFavourited: false,
            isReblogged: false
        )
    }

    // MARK: - Writing the outcome back

    @Test("The owning account's answer is written whole")
    @MainActor
    func owningAccountWritesEverything() {
        let item = post()

        StatusInteractions.apply(
            StatusInteractions.Outcome(
                isFavourited: true,
                isReblogged: false,
                favouriteCount: 4,
                reblogCount: 2,
                describesOwningAccount: true
            ),
            to: item
        )

        #expect(item.isFavourited == true)
        #expect(item.favouriteCount == 4)
    }

    /// The case worth having a test for. Boosting as a *second* account and then recording
    /// `isReblogged` on this row would make it offer "Remove Boost" to the first account — which
    /// would either fail or, worse, undo a boost that account never made.
    @Test("Another account's answer moves the counts but not the flags")
    @MainActor
    func otherAccountLeavesFlagsAlone() {
        let item = post()

        StatusInteractions.apply(
            StatusInteractions.Outcome(
                isFavourited: true,
                isReblogged: true,
                favouriteCount: 9,
                reblogCount: 7,
                describesOwningAccount: false
            ),
            to: item
        )

        // A count is a fact about the post and true whoever asked.
        #expect(item.favouriteCount == 9)
        #expect(item.reblogCount == 7)
        // The flags are one account's state, and not this row's account.
        #expect(item.isFavourited == false)
        #expect(item.isReblogged == false)
    }

    /// An instance that omits the field has not said "no". Overwriting a known state with
    /// "unknown" is strictly worse than keeping it.
    @Test("A flag the server omitted does not erase the one on the row")
    @MainActor
    func omittedFlagIsNotAnAnswer() {
        let item = post()
        item.isFavourited = true

        StatusInteractions.apply(
            StatusInteractions.Outcome(
                isFavourited: nil,
                isReblogged: nil,
                favouriteCount: 3,
                reblogCount: 2,
                describesOwningAccount: true
            ),
            to: item
        )

        #expect(item.isFavourited == true)
    }

    // MARK: - Failures

    @Test("A refused write is reported as a scope to grant, not as a dead token")
    func refusedWriteMapsToScope() {
        let failure = StatusInteractions.failure(from: MastodonError.writeNotAuthorized, account: "Home")

        #expect(failure == .writeNotAuthorized(account: "Home"))
    }

    @Test("A revoked token stays a revoked token")
    func revokedMapsToRevoked() {
        #expect(
            StatusInteractions.failure(from: MastodonError.tokenRevoked, account: "Home")
                == .tokenRevoked(account: "Home")
        )
    }

    /// A deleted post, or one the acting instance will not serve. Worth telling apart from the
    /// catch-all, because retrying will never work.
    @Test("Gone means gone", arguments: [404, 410])
    func goneMapsToNotFound(code: Int) {
        #expect(
            StatusInteractions.failure(from: HTTPError.status(code: code, body: ""), account: "Home")
                == .notFoundOnInstance(account: "Home")
        )
    }

    @Test("Anything else is the catch-all")
    func otherwiseFailed() {
        #expect(StatusInteractions.failure(from: URLError(.timedOut), account: "Home") == .failed)
        #expect(
            StatusInteractions.failure(from: HTTPError.status(code: 500, body: "boom"), account: "Home")
                == .failed
        )
    }

    /// The rule that matters more than any single mapping: a client error can carry the
    /// `URLRequest` that produced it, and that request's `Authorization` header is the account's
    /// access token. So nothing a failure carries may come from the error itself.
    @Test("A failure never carries anything from the error it came from")
    func failureNeverCarriesTheError() {
        let leaky = HTTPError.status(code: 500, body: "Bearer super-secret-token")
        let failure = StatusInteractions.failure(from: leaky, account: "Home")

        #expect(failure == .failed)
        #expect(!String(describing: failure).contains("super-secret-token"))
        #expect(!String(describing: failure).contains("Bearer"))
    }
}
