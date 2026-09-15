import Foundation
import ReadReadModel
import Testing

/// The two questions a sign-in has to ask the account list.
///
/// Both exist because of one bug: on an instance the reader was already signed in to, Mastodon
/// handed back an authorisation for the account already logged in without showing anything at all,
/// so "add another account" added a second copy of the first one.
///
/// The first question finds the *record*, not a yes-or-no, because a sign-in that lands on an
/// account already present renews it rather than being refused — signing in again is the only way
/// an account's granted scopes can widen.
@Suite("Account duplicates")
struct AccountDuplicateTests {

    private func account(
        kind: AccountKind = .mastodon,
        server: String,
        username: String
    ) -> AccountRecord {
        AccountRecord(
            kind: kind,
            displayName: "@\(username)",
            serverURLString: server,
            username: username
        )
    }

    private func identity(server: String, username: String, kind: AccountKind = .mastodon) -> AccountIdentity {
        AccountIdentity(
            kindRaw: kind.rawValue,
            serverURLString: server,
            username: username
        )
    }

    // MARK: - Already added

    /// Returns the record, and it has to be the *right* one: that record's id is the Keychain key
    /// the renewed token is written under, so matching the wrong one would hand account A's token
    /// to account B.
    @Test("The same account on the same instance is found")
    func sameAccountIsFound() {
        let mine = account(server: "https://mastodon.social", username: "matze")
        let other = account(server: "https://mastodon.social", username: "someone-else")

        let found = AccountIdentity.account(
            matching: identity(server: "https://mastodon.social", username: "matze"),
            in: [other, mine]
        )

        #expect(found?.id == mine.id)
    }

    /// The case the whole change is for: a *different* account on the same instance has to be
    /// allowed through.
    @Test("A second account on the same instance is not")
    func secondAccountIsNotFound() {
        let accounts = [account(server: "https://mastodon.social", username: "matze")]

        #expect(AccountIdentity.account(
            matching: identity(server: "https://mastodon.social", username: "someone-else"),
            in: accounts
        ) == nil)
    }

    /// Normalised, because the same server is typed differently on a phone and a Mac. Two records
    /// that differ only in a scheme or a trailing slash are the same account, and comparing the
    /// strings would let a duplicate through.
    @Test("Server addresses compare normalised", arguments: [
        "mastodon.social",
        "https://mastodon.social",
        "https://mastodon.social/",
        "HTTPS://Mastodon.Social",
    ])
    func serverComparisonIsNormalised(typed: String) {
        let accounts = [account(server: "https://mastodon.social", username: "matze")]

        #expect(AccountIdentity.account(
            matching: identity(server: typed, username: "MATZE"),
            in: accounts
        ) != nil)
    }

    @Test("The same handle on another instance is a different account")
    func sameHandleElsewhereIsDifferent() {
        let accounts = [account(server: "https://mastodon.social", username: "matze")]

        #expect(AccountIdentity.account(
            matching: identity(server: "https://chaos.social", username: "matze"),
            in: accounts
        ) == nil)
    }

    /// A FreshRSS account on a host that happens to also serve Mastodon must not block a Mastodon
    /// sign-in to it — which is exactly the shape of a self-hosted setup.
    @Test("Another kind of account on the same host is a different account")
    func otherKindIsDifferent() {
        let accounts = [account(kind: .freshRSS, server: "https://example.net", username: "matze")]

        #expect(AccountIdentity.account(
            matching: identity(server: "https://example.net", username: "matze"),
            in: accounts
        ) == nil)
    }

    // MARK: - Already signed in to the server

    /// Asked *before* the browser opens, when the username is not known yet — so it must not be
    /// part of the comparison.
    @Test("Any account on the server counts, whoever it belongs to")
    func anyAccountOnServerCounts() {
        let accounts = [account(server: "https://mastodon.social", username: "matze")]

        #expect(AccountIdentity.hasAccount(
            kindRaw: AccountKind.mastodon.rawValue,
            onSameServerAs: identity(server: "mastodon.social", username: ""),
            in: accounts
        ))
    }

    @Test("A different server does not count")
    func differentServerDoesNotCount() {
        let accounts = [account(server: "https://mastodon.social", username: "matze")]

        #expect(!AccountIdentity.hasAccount(
            kindRaw: AccountKind.mastodon.rawValue,
            onSameServerAs: identity(server: "chaos.social", username: ""),
            in: accounts
        ))
    }

    /// A first account must not be sent through the "ask who this is" path: somebody already
    /// signed in to their instance should not be made to type a password to add their own reader.
    @Test("An empty list means this is a first account")
    func emptyListMeansFirstAccount() {
        #expect(!AccountIdentity.hasAccount(
            kindRaw: AccountKind.mastodon.rawValue,
            onSameServerAs: identity(server: "mastodon.social", username: ""),
            in: []
        ))
    }

    @Test("A FreshRSS account on the host does not count as a Mastodon one")
    func otherKindOnHostDoesNotCount() {
        let accounts = [account(kind: .freshRSS, server: "https://example.net", username: "matze")]

        #expect(!AccountIdentity.hasAccount(
            kindRaw: AccountKind.mastodon.rawValue,
            onSameServerAs: identity(server: "example.net", username: ""),
            in: accounts
        ))
    }
}
