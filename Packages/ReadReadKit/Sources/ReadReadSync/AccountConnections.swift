import Foundation
import FreshRSSAPI
import MastodonAPI
import ReadReadModel
import ReadReadSupport
import SwiftData

/// A configured account paired with a client that can talk to it.
public enum AccountConnection: Sendable {
    case freshRSS(accountID: UUID, client: GReaderClient)
    case mastodon(accountID: UUID, client: MastodonClient)

    public var accountID: UUID {
        switch self {
        case .freshRSS(let id, _), .mastodon(let id, _): id
        }
    }

    /// Which refresh cadence this connection belongs to.
    public var refreshKind: RefreshKind {
        switch self {
        case .freshRSS: .freshRSSFeeds
        case .mastodon: .mastodonFeeds
        }
    }
}

/// Why an account could not be connected.
public enum AccountConnectionError: Error, Sendable, Equatable {
    case missingCredential(accountID: UUID, displayName: String)
    case invalidServerURL(accountID: UUID, displayName: String)
}

/// Turns stored `AccountRecord`s into clients.
///
/// Rebuilt for every refresh rather than held, and that is deliberate. A long-lived client would
/// go stale the moment an account is signed out, re-authenticated or disabled, and the symptom —
/// a timeline that keeps refreshing from a server the user thought they had removed — is both
/// alarming and hard to trace. Building costs one Keychain read per account.
///
/// **Credentials never leave here.** The clients hold them, the callers never see them, and
/// nothing above this type has a way to ask for one.
public struct AccountConnections: Sendable {

    private let keychain: KeychainStore
    private let http: HTTPClient

    public init(keychain: KeychainStore = KeychainStore(), http: HTTPClient = HTTPClient()) {
        self.keychain = keychain
        self.http = http
    }

    /// Builds a client for every enabled account, reporting the ones that could not be built.
    ///
    /// Failures are returned alongside the successes instead of thrown, because one account with a
    /// missing password must not stop the others refreshing — and the settings screen needs
    /// something specific to show beside the account that is broken.
    public func connect(_ accounts: [AccountRecord]) -> (
        connections: [AccountConnection],
        failures: [AccountConnectionError]
    ) {
        var connections: [AccountConnection] = []
        var failures: [AccountConnectionError] = []

        for account in accounts where account.isEnabled {
            do {
                connections.append(try connect(account))
            } catch let error as AccountConnectionError {
                failures.append(error)
            } catch {
                failures.append(.missingCredential(
                    accountID: account.id,
                    displayName: account.displayName
                ))
            }
        }

        return (connections, failures)
    }

    public func connect(_ account: AccountRecord) throws -> AccountConnection {
        guard let serverURL = account.serverURL else {
            throw AccountConnectionError.invalidServerURL(
                accountID: account.id,
                displayName: account.displayName
            )
        }

        switch account.kind {
        case .freshRSS:
            guard let password = try keychain.string(
                for: .freshRSSAPIPassword,
                key: account.id.uuidString
            ) else {
                throw AccountConnectionError.missingCredential(
                    accountID: account.id,
                    displayName: account.displayName
                )
            }

            return .freshRSS(accountID: account.id, client: GReaderClient(
                baseURL: serverURL,
                credentials: .init(username: account.username, apiPassword: password),
                http: http
            ))

        case .mastodon:
            guard let token = try keychain.string(
                for: .mastodonAccessToken,
                key: account.id.uuidString
            ) else {
                throw AccountConnectionError.missingCredential(
                    accountID: account.id,
                    displayName: account.displayName
                )
            }

            return .mastodon(accountID: account.id, client: MastodonClient(
                instanceURL: serverURL,
                accessToken: token,
                http: http
            ))
        }
    }

    // MARK: - Sign-in state

    /// Whether this device holds the secret the account needs.
    ///
    /// Asked by the accounts pane of every row, because an account list that syncs while
    /// credentials deliberately do not means a second device receives accounts it is **not signed
    /// in to** — and until something says so, the only evidence is an empty timeline and a line in
    /// the last-refresh report.
    ///
    /// Deliberately not "is the credential still *valid*": that is a network round trip per
    /// account, and it answers a different question. A revoked token still reads as signed in here
    /// and fails at the next refresh, which is where a server's decision belongs.
    public func hasCredential(forAccountID id: UUID, kind: AccountKind) -> Bool {
        let purpose: KeychainStore.Purpose = switch kind {
        case .freshRSS: .freshRSSAPIPassword
        case .mastodon: .mastodonAccessToken
        }
        return ((try? keychain.string(for: purpose, key: id.uuidString)) ?? nil) != nil
    }

    /// Which of these accounts this device can sign in as, asked off the calling actor.
    ///
    /// Takes ids and kinds rather than records for the same reason `forgetCredentials(forAccountID:)`
    /// does: `AccountRecord` is a SwiftData model and cannot cross into the detached task that keeps
    /// a Keychain read off the main actor. Against the legacy login keychain that read can stop dead
    /// behind a SecurityAgent prompt, and on the main actor it takes the window down with it.
    public func signedInAccountIDs(among accounts: [(id: UUID, kind: AccountKind)]) async -> Set<UUID> {
        let accounts = accounts
        let connections = self
        return await Task.detached(priority: .userInitiated) {
            Set(accounts.filter { connections.hasCredential(forAccountID: $0.id, kind: $0.kind) }
                .map(\.id))
        }.value
    }

    /// Removes everything stored for an account.
    ///
    /// Called when an account is deleted. The Mastodon *client registration* is deliberately left
    /// alone: it is keyed by instance host, not by account, so wiping it would break a second
    /// account on the same instance and force a fresh app registration on the user's server.
    public func forgetCredentials(for account: AccountRecord) throws {
        try forgetCredentials(forAccountID: account.id)
    }

    /// The same, keyed by id.
    ///
    /// Needed because `AccountRecord` is a SwiftData model and so cannot cross into the detached
    /// task that keeps this Keychain call off the main actor — the id is all this ever wanted.
    public func forgetCredentials(forAccountID id: UUID) throws {
        try keychain.removeAll(forAccountKey: id.uuidString)
    }

    /// The same, off the calling actor.
    ///
    /// Used where the removal was not the reader's own press of a button — an account deleted on
    /// another device, arriving by sync — so there is no sheet to freeze but also nobody waiting,
    /// and a Keychain call that stops behind a SecurityAgent prompt would hold up the sync run.
    public func forgetCredentials(forAccountID id: UUID) async throws {
        try await keychain.removeAll(forAccountKey: id.uuidString)
    }
}
