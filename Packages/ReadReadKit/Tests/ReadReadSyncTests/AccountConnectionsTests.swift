import Foundation
import ReadReadModel
import ReadReadSupport
import Testing

@testable import ReadReadSync

@Suite("AccountConnections")
struct AccountConnectionsTests {

    private func makeKeychain() -> KeychainStore {
        // The data-protection keychain can never work here: the test binary is not sandboxed and
        // carries no entitlements, so every call to it returns `errSecMissingEntitlement`. The
        // store would fall back on its own; skipping the probe just saves a wasted call per
        // operation.
        KeychainStore(
            service: "com.kittmedia.ReadRead.tests.\(UUID().uuidString)",
            prefersDataProtectionKeychain: false
        )
    }

    private func freshRSSAccount(enabled: Bool = true) -> AccountRecord {
        let account = AccountRecord(
            kind: .freshRSS,
            displayName: "Home FreshRSS",
            serverURLString: "https://rss.example.com",
            username: "matze"
        )
        account.isEnabled = enabled
        return account
    }

    private func mastodonAccount() -> AccountRecord {
        AccountRecord(
            kind: .mastodon,
            displayName: "@matze@mastodon.social",
            serverURLString: "https://mastodon.social",
            username: "matze"
        )
    }

    @Test("An account with its credential connects")
    func connectsWithCredential() throws {
        let keychain = makeKeychain()
        let account = freshRSSAccount()
        try keychain.setString("api-password", for: .freshRSSAPIPassword, key: account.id.uuidString)

        let result = AccountConnections(keychain: keychain).connect([account])

        #expect(result.failures.isEmpty)
        #expect(result.connections.count == 1)
        #expect(result.connections.first?.refreshKind == .freshRSSFeeds)
    }

    @Test("A Mastodon account refreshes on its own cadence")
    func mastodonUsesItsOwnCadence() throws {
        let keychain = makeKeychain()
        let account = mastodonAccount()
        try keychain.setString("token", for: .mastodonAccessToken, key: account.id.uuidString)

        let result = AccountConnections(keychain: keychain).connect([account])

        // The split exists because a Mastodon timeline moves far faster than an RSS river; if both
        // resolved to the same kind, one interval would silently govern both.
        #expect(result.connections.first?.refreshKind == .mastodonFeeds)
    }

    @Test("A missing credential is reported, not thrown")
    func missingCredentialIsReported() {
        let account = freshRSSAccount()

        let result = AccountConnections(keychain: makeKeychain()).connect([account])

        #expect(result.connections.isEmpty)
        #expect(result.failures == [
            .missingCredential(accountID: account.id, displayName: "Home FreshRSS"),
        ])
    }

    @Test("One broken account does not stop the others connecting")
    func oneFailureDoesNotStopTheRest() throws {
        let keychain = makeKeychain()
        let working = freshRSSAccount()
        let broken = mastodonAccount()
        try keychain.setString("api-password", for: .freshRSSAPIPassword, key: working.id.uuidString)

        let result = AccountConnections(keychain: keychain).connect([working, broken])

        // The whole reason failures are returned alongside successes: a signed-out Mastodon account
        // must not stop the feeds refreshing.
        #expect(result.connections.count == 1)
        #expect(result.failures.count == 1)
    }

    @Test("A disabled account is skipped entirely")
    func disabledAccountIsSkipped() throws {
        let keychain = makeKeychain()
        let account = freshRSSAccount(enabled: false)
        try keychain.setString("api-password", for: .freshRSSAPIPassword, key: account.id.uuidString)

        let result = AccountConnections(keychain: keychain).connect([account])

        // Skipped, not failed. Switching an account off is a choice, and reporting it as a problem
        // would fill the settings screen with warnings about something working as asked.
        #expect(result.connections.isEmpty)
        #expect(result.failures.isEmpty)
    }

    @Test("An unusable server address is reported as such")
    func invalidServerURL() throws {
        let keychain = makeKeychain()
        let account = freshRSSAccount()
        account.serverURLString = "not a url"
        try keychain.setString("api-password", for: .freshRSSAPIPassword, key: account.id.uuidString)

        let result = AccountConnections(keychain: keychain).connect([account])

        #expect(result.failures == [
            .invalidServerURL(accountID: account.id, displayName: "Home FreshRSS"),
        ])
    }

    // MARK: - Sign-in state

    @Test("An account with no credential here reads as signed out")
    func signedOutAccountIsReported() async throws {
        let keychain = makeKeychain()
        let signedIn = mastodonAccount()
        // The shape a second device is in: the account list has synced, the token has not and never
        // will, and nothing in the record itself distinguishes the two.
        let arrivedBySync = mastodonAccount()
        // `await`ed because this test is async and the overload set then resolves to the
        // off-the-actor variant; same write either way.
        try await keychain.setString("token", for: .mastodonAccessToken, key: signedIn.id.uuidString)

        let ids = await AccountConnections(keychain: keychain).signedInAccountIDs(among: [
            (id: signedIn.id, kind: .mastodon),
            (id: arrivedBySync.id, kind: .mastodon),
        ])

        #expect(ids == [signedIn.id])
    }

    @Test("A credential of the wrong kind does not count as signed in")
    func credentialIsMatchedToTheAccountKind() throws {
        let keychain = makeKeychain()
        let account = mastodonAccount()
        try keychain.setString("api-password", for: .freshRSSAPIPassword, key: account.id.uuidString)

        // The purposes are namespaced in the Keychain, so this could only pass by asking the wrong
        // one — and a Mastodon account reported as signed in because a FreshRSS password happens to
        // share its id would offer no way to fix the account that is actually broken.
        let connections = AccountConnections(keychain: keychain)
        #expect(!connections.hasCredential(forAccountID: account.id, kind: .mastodon))
        #expect(connections.hasCredential(forAccountID: account.id, kind: .freshRSS))
    }

    @Test("A disabled account still reports its credential")
    func disabledAccountsStillReportCredentials() throws {
        let keychain = makeKeychain()
        let account = freshRSSAccount(enabled: false)
        try keychain.setString("api-password", for: .freshRSSAPIPassword, key: account.id.uuidString)

        // Unlike `connect`, which skips a disabled account entirely. Switched off and signed out are
        // different states and the accounts pane shows both, so answering "signed out" for an
        // account that is merely paused would offer a Sign In button for a credential already there.
        #expect(AccountConnections(keychain: keychain).hasCredential(forAccountID: account.id, kind: .freshRSS))
    }

    @Test("Signing out removes the account's secrets")
    func forgettingCredentials() throws {
        let keychain = makeKeychain()
        let account = freshRSSAccount()
        try keychain.setString("api-password", for: .freshRSSAPIPassword, key: account.id.uuidString)

        try AccountConnections(keychain: keychain).forgetCredentials(for: account)

        #expect(try keychain.string(for: .freshRSSAPIPassword, key: account.id.uuidString) == nil)
    }

    @Test("Signing out leaves the instance's app registration alone")
    func forgettingKeepsClientRegistration() throws {
        let keychain = makeKeychain()
        let account = mastodonAccount()
        try keychain.setString("token", for: .mastodonAccessToken, key: account.id.uuidString)
        try keychain.setString("{}", for: .mastodonClientCredentials, key: "mastodon.social")

        try AccountConnections(keychain: keychain).forgetCredentials(for: account)

        // Keyed by instance host, not by account: wiping it would break a second account on the
        // same instance and force a fresh app registration on the user's server.
        #expect(try keychain.string(for: .mastodonAccessToken, key: account.id.uuidString) == nil)
        #expect(try keychain.string(for: .mastodonClientCredentials, key: "mastodon.social") == "{}")
    }
}
