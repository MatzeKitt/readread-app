import Foundation
import MastodonAPI
import ReadReadModel
import ReadReadSupport

/// Favouriting and boosting a Mastodon post, as any of the reader's accounts.
///
/// The first thing in this app that *writes* to a server. Everything else — FreshRSS included, and
/// deliberately — only ever reads, so the boundary is worth drawing sharply: this type is the whole
/// of the write surface, it touches nothing but the four action endpoints, and it is reached only
/// from a menu the reader opened on a post they were looking at. Nothing here runs on a timer.
///
/// Credentials never leave it. The token is read from the Keychain, handed straight to a client
/// built for the one call, and dropped — the same arrangement `AccountConnections` uses, and for
/// the same reason: nothing above this has any way to ask for one.
public struct StatusInteractions: Sendable {

    public enum Action: Sendable, Equatable {
        case favourite(isOn: Bool)
        case boost(isOn: Bool)
    }

    /// Why an action could not be carried out, in terms the UI can turn into a sentence.
    ///
    /// Each case exists because it has a *different* answer for the reader. That is also why none
    /// of them carries the underlying error: a `MastodonError` or an `HTTPError` can hold the
    /// request that produced it, and that request's header carries the access token — so the
    /// message shown is always built from the case, never interpolated from the error.
    public enum Failure: Error, Sendable, Equatable {

        /// The item is not a Mastodon post, or its stored payload will not decode.
        case notAStatus

        /// No credential for the account chosen. It has been signed out, or the Keychain item is
        /// gone.
        case missingCredential(account: String)

        /// The account's address is unusable.
        case invalidServerURL(account: String)

        /// The token predates this app asking for write scopes. Signing in again is the fix, and
        /// it is the failure a reader hits first after this feature ships.
        case writeNotAuthorized(account: String)

        /// The token has been revoked at the instance.
        case tokenRevoked(account: String)

        /// The chosen account's instance cannot find the post. Only reachable when acting as an
        /// account other than the one the post arrived in.
        case notFoundOnInstance(account: String)

        /// Anything else: the instance is down, the network is gone, the post was deleted.
        case failed
    }

    /// What the server said afterwards, ready to be written onto the row.
    ///
    /// Read back rather than assumed. The counts are the instance's, and a reader who boosts a
    /// post whose boost count has moved since the last refresh should see the true figure rather
    /// than the stale one plus one.
    public struct Outcome: Sendable, Equatable {

        public var isFavourited: Bool?
        public var isReblogged: Bool?
        public var favouriteCount: Int
        public var reblogCount: Int

        /// Whether the flags describe the account that owns the row.
        ///
        /// False when the reader acted as one of their *other* accounts. The counts are still
        /// worth taking — they are a property of the post, not of the viewer — but the flags are
        /// that other account's state, and writing them onto this row would make it claim the
        /// owning account had liked something it had not. See ``apply(_:to:)``.
        public var describesOwningAccount: Bool

        public init(
            isFavourited: Bool?,
            isReblogged: Bool?,
            favouriteCount: Int,
            reblogCount: Int,
            describesOwningAccount: Bool
        ) {
            self.isFavourited = isFavourited
            self.isReblogged = isReblogged
            self.favouriteCount = favouriteCount
            self.reblogCount = reblogCount
            self.describesOwningAccount = describesOwningAccount
        }
    }

    /// The account to act as, reduced to plain values.
    ///
    /// A struct rather than the `AccountRecord`, because a SwiftData model is not `Sendable` and
    /// this work has to leave the main actor — the Keychain read alone can block behind a
    /// SecurityAgent prompt, which on the main actor freezes the window that would show it.
    public struct Actor: Sendable, Equatable {

        public var id: UUID
        public var displayName: String
        public var serverURLString: String?

        public init(id: UUID, displayName: String, serverURLString: String?) {
            self.id = id
            self.displayName = displayName
            self.serverURLString = serverURLString
        }
    }

    private let keychain: KeychainStore
    private let http: HTTPClient

    public init(keychain: KeychainStore = KeychainStore(), http: HTTPClient = HTTPClient()) {
        self.keychain = keychain
        self.http = http
    }

    /// Carries out one action.
    ///
    /// - Parameters:
    ///   - statusID: The **displayed** status's id on the *owning* account's instance. Ignored when
    ///     acting as another account, which cannot use it.
    ///   - statusURL: The post's public URL. Required only for the cross-account case, where it is
    ///     the sole name for the post both instances agree on.
    ///   - isOwningAccount: Whether `account` is the one whose timeline the post arrived in.
    public func perform(
        _ action: Action,
        statusID: String,
        statusURL: URL?,
        as account: Actor,
        isOwningAccount: Bool
    ) async throws -> Outcome {
        guard
            let serverURLString = account.serverURLString,
            let serverURL = URL(string: serverURLString)
        else {
            throw Failure.invalidServerURL(account: account.displayName)
        }

        guard let token = try? await keychain.string(
            for: .mastodonAccessToken,
            key: account.id.uuidString
        ), !token.isEmpty else {
            throw Failure.missingCredential(account: account.displayName)
        }

        let client = MastodonClient(instanceURL: serverURL, accessToken: token, http: http)

        // Which id to act on. The owning account's instance minted the one the row already holds;
        // any other account has to be told the URL and asked what it calls the post.
        let targetID: MastodonStatusID
        if isOwningAccount {
            targetID = MastodonStatusID(statusID)
        } else {
            guard let statusURL else {
                throw Failure.notFoundOnInstance(account: account.displayName)
            }
            do {
                guard let resolved = try await client.resolveStatus(url: statusURL) else {
                    throw Failure.notFoundOnInstance(account: account.displayName)
                }
                targetID = resolved.displayStatus.id
            } catch let failure as Failure {
                throw failure
            } catch {
                throw Self.failure(from: error, account: account.displayName)
            }
        }

        do {
            let updated: MastodonStatus
            switch action {
            case .favourite(let isOn):
                updated = try await client.favourite(targetID, isOn: isOn)
            case .boost(let isOn):
                updated = try await client.reblog(targetID, isOn: isOn)
            }

            // `displayStatus`, because boosting answers with the wrapper the server just created:
            // its own counts are zero and its own flags describe the boost, so reading the outer
            // status would blank the row.
            let subject = updated.displayStatus
            return Outcome(
                isFavourited: subject.favourited,
                isReblogged: subject.reblogged,
                favouriteCount: subject.favouritesCount,
                reblogCount: subject.reblogsCount,
                describesOwningAccount: isOwningAccount
            )
        } catch {
            throw Self.failure(from: error, account: account.displayName)
        }
    }

    /// Writes an outcome onto the row the reader acted on.
    ///
    /// The counts always, the flags only when the acting account owns the row. That asymmetry is
    /// the whole of it: a post's favourite count is a fact about the post and true whoever asked,
    /// while "favourited" is a fact about one account. Boosting as a second account and then
    /// writing `isReblogged = true` here would make the row offer *Unboost* to the first account,
    /// which would fail — or worse, succeed against a boost it never made.
    ///
    /// Does not save. The caller owns the context and knows whether anything else is pending.
    @MainActor
    public static func apply(_ outcome: Outcome, to item: CachedItem) {
        item.favouriteCount = outcome.favouriteCount
        item.reblogCount = outcome.reblogCount

        guard outcome.describesOwningAccount else { return }
        // Only when the server actually said. A nil here would mean the instance omitted the
        // field, and overwriting a known state with "unknown" is strictly worse than keeping it.
        if let isFavourited = outcome.isFavourited { item.isFavourited = isFavourited }
        if let isReblogged = outcome.isReblogged { item.isReblogged = isReblogged }
    }

    /// Maps a client error onto a case, discarding the error itself.
    ///
    /// Case by case, and never interpolating the error's own description: a `MastodonError` or an
    /// `HTTPError` can carry the `URLRequest` that produced it, whose `Authorization` header is the
    /// account's token. Anything printed from one of these would put that token on screen and into
    /// whatever the reader pasted it into.
    static func failure(from error: any Error, account: String) -> Failure {
        if let failure = error as? Failure { return failure }

        if let mastodon = error as? MastodonError {
            switch mastodon {
            case .writeNotAuthorized: return .writeNotAuthorized(account: account)
            case .tokenRevoked: return .tokenRevoked(account: account)
            case .statusNotFound: return .notFoundOnInstance(account: account)
            case .invalidInstanceURL: return .invalidServerURL(account: account)
            case .unexpectedResponse, .authorizationFailed: return .failed
            }
        }

        if let http = error as? HTTPError, case .status(let code, _) = http {
            // A deleted post, or one the acting instance will not serve. Distinguished from the
            // catch-all because "gone" is worth saying: retrying will never work.
            if code == 404 || code == 410 { return .notFoundOnInstance(account: account) }
        }

        return .failed
    }
}
