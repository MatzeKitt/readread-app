import AuthenticationServices
import Foundation
import ReadReadSupport

/// Runs the browser half of the OAuth flow.
///
/// `ASWebAuthenticationSession` rather than opening Safari or embedding a web view. It is the only
/// option that gets all three of these at once: the callback is matched by URL scheme *inside the
/// system*, so no other app on the device can claim it; the user can see the real instance domain
/// and its TLS state, which is what lets them tell a genuine login from a phishing page; and the
/// app never has access to the credentials they type.
@MainActor
public final class MastodonAuthorizationSession {

    /// Supplies the window the sheet is anchored to.
    ///
    /// Injected rather than reached for, because the anchor differs per platform and this type
    /// should not have to know which one it is running on.
    public typealias AnchorProvider = @MainActor () -> ASPresentationAnchor

    private let anchorProvider: AnchorProvider
    private var session: ASWebAuthenticationSession?

    /// Retained for the lifetime of the session: `ASWebAuthenticationSession` holds its context
    /// provider weakly, and letting it deallocate cancels the flow with no explanation.
    private var contextProvider: ContextProvider?

    public init(anchorProvider: @escaping AnchorProvider) {
        self.anchorProvider = anchorProvider
    }

    /// Presents the instance's authorisation page and returns the callback URL.
    ///
    /// - Parameter isEphemeral: Whether to run without the browser's cookies. Set when adding a
    ///   *second* account on an instance, alongside `force_login` on the URL — see
    ///   ``MastodonOAuth/authorizationURL(credentials:forcesLogin:)``. Belt and braces on purpose:
    ///   `force_login` is the instance's mechanism and needs the instance to honour it, while a
    ///   session with no cookies has nobody to be logged in as and therefore cannot skip the login
    ///   form whatever the server does. It also keeps the reader's own browser session out of it,
    ///   which matters because `force_login` signs the current web session out on the way past —
    ///   a side effect worth not inflicting on the tab they had open.
    /// - Throws: `MastodonError.authorizationFailed` if the user cancels, which is an ordinary
    ///   outcome rather than an error to report as a failure.
    public func authorize(url: URL, isEphemeral: Bool = false) async throws -> URL {
        // The scheme is passed separately so the system can match the callback itself. It must be
        // the scheme registered in `CFBundleURLTypes` or the callback never arrives.
        let callbackScheme = URL(string: MastodonOAuth.redirectURI)?.scheme ?? "readread"

        // The anchor is resolved *now*, on the main actor, and handed to the provider as a value.
        // Asking for it inside `presentationAnchor(for:)` instead means running main-actor code on
        // whatever thread AuthenticationServices calls from, which is not guaranteed to be main.
        //
        // This is a second instance of the hazard the completion handler below documents, not a
        // duplicate defence against the same one — the two are different callbacks reached by
        // different paths, and each has to opt out of the enclosing actor on its own.
        let provider = ContextProvider(anchor: anchorProvider())
        contextProvider = provider

        return try await withCheckedThrowingContinuation { continuation in
            // Bound to a `@Sendable` constant before it is handed over, and that is the entire
            // point of writing it this way.
            //
            // This type is `@MainActor`, and a closure written inline inside a `@MainActor` method
            // *inherits* that isolation — so the compiler emits an executor check at its entry.
            // AuthenticationServices calls this handler from an `NSXPCConnection` reply queue, the
            // check fails, and `dispatch_assert_queue` kills the process. Not a hang, not an
            // error: a `SIGTRAP` in libdispatch with a stack that names XPC and never mentions
            // isolation, which is why this survived two previous attempts at it aimed elsewhere.
            //
            // Declaring the type explicitly as `@Sendable` opts the closure *out* of inheriting
            // the actor, so it runs wherever it is called and no check is emitted. Sound because
            // the body touches nothing actor-protected: a continuation may be resumed from any
            // thread, and everything else here is a value.
            let completion: @Sendable (URL?, (any Error)?) -> Void = { callbackURL, error in
                if let error {
                    let code = (error as NSError).code
                    if code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                        continuation.resume(throwing: MastodonError.authorizationFailed("Cancelled"))
                    } else {
                        continuation.resume(throwing: error)
                    }
                    return
                }
                guard let callbackURL else {
                    continuation.resume(throwing: MastodonError.authorizationFailed("No callback URL"))
                    return
                }
                continuation.resume(returning: callbackURL)
            }

            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: callbackScheme,
                completionHandler: completion
            )

            session.presentationContextProvider = provider
            // Ordinarily not ephemeral: reusing the browser's cookies means someone already signed
            // in to their instance is not made to type their password again.
            //
            // The exception is adding a second account on the same instance, and the comment that
            // used to sit here — "adding a second account still works because the instance shows
            // an account picker" — was simply wrong. Mastodon shows no picker. With a live session
            // and an app already authorised for these scopes it redirects straight back with a
            // code for the account already logged in, so nothing appeared on screen and the second
            // account was a copy of the first. See the `isEphemeral` parameter above.
            session.prefersEphemeralWebBrowserSession = isEphemeral

            self.session = session

            if !session.start() {
                continuation.resume(throwing: MastodonError.authorizationFailed("Could not start the authorization session"))
            }
        }
    }

    public func cancel() {
        session?.cancel()
        session = nil
        contextProvider = nil
    }

    /// Hands the system the window to anchor the sheet to.
    ///
    /// Holds the anchor rather than a closure that produces one: this method is called by
    /// AuthenticationServices on a thread of its choosing, so it must do nothing that assumes an
    /// actor. Returning a stored reference is the only thing safe to do here.
    private final class ContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {

        private let anchor: ASPresentationAnchor

        init(anchor: ASPresentationAnchor) {
            self.anchor = anchor
        }

        func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
            anchor
        }
    }
}

/// Drives the whole sign-in: register, authorise, exchange, verify.
///
/// Sequenced in one place because the steps are order-dependent and each depends on the previous
/// one's output, so splitting them across the UI layer would invite doing them out of order.
@MainActor
public struct MastodonSignIn {

    private let keychain: KeychainStore
    private let http: HTTPClient

    public init(keychain: KeychainStore = KeychainStore(), http: HTTPClient = HTTPClient()) {
        self.keychain = keychain
        self.http = http
    }

    public struct Result: Sendable {
        public var instanceURL: URL
        public var accessToken: String
        public var account: MastodonCredentialAccount
    }

    /// Signs in to an instance, storing the secrets in the Keychain.
    ///
    /// - Parameters:
    ///   - instanceInput: Whatever the user typed — `mastodon.social`, `@me@mastodon.social`, or a
    ///     full URL.
    ///   - isAddingAnotherAccount: Whether the app already holds an account on this instance.
    ///
    ///     When it does, the instance has to be *made* to ask who is signing in. Left to itself it
    ///     sees a live web session and an app already authorised for these scopes, skips both the
    ///     login form and the consent screen, and redirects straight back with a code for whoever
    ///     is logged in — so nothing appears on screen and the app ends up with a second copy of
    ///     the account it already had. There is nothing in the callback to detect that from; it is
    ///     a valid code for a valid account.
    ///
    ///     The caller passes this in because it knows: this type has no access to the account
    ///     list, and deliberately so.
    public func signIn(
        instanceInput: String,
        session: MastodonAuthorizationSession,
        isAddingAnotherAccount: Bool = false
    ) async throws -> Result {
        guard let instanceURL = MastodonClient.normalisedInstanceURL(from: instanceInput) else {
            throw MastodonError.invalidInstanceURL(instanceInput)
        }
        guard let host = instanceURL.host() else {
            throw MastodonError.invalidInstanceURL(instanceInput)
        }

        let oauth = MastodonOAuth(instanceURL: instanceURL, http: http)

        // Reuse an existing registration for this instance. Registering again would work, but it
        // leaves an orphaned app entry in the user's instance settings on every sign-in.
        let credentials: MastodonClientCredentials
        // Awaited, so the Keychain work happens off the main actor: this type is `@MainActor` for
        // `ASWebAuthenticationSession`'s sake, and a synchronous read here would freeze the sheet
        // behind a SecurityAgent prompt.
        if let stored = try await keychain.value(
            MastodonClientCredentials.self,
            for: .mastodonClientCredentials,
            key: host
        ), stored.scopes == MastodonOAuth.scopes {
            credentials = stored
        } else {
            // A stored registration with different scopes is unusable: the instance rejects an
            // authorise request for scopes the app was not registered with.
            credentials = try await oauth.register()
            try await keychain.setValue(credentials, for: .mastodonClientCredentials, key: host)
        }

        // Both halves of "ask who this is", and only when there is an account to be confused
        // with. `force_login` is the instance's own mechanism; the ephemeral session is what makes
        // it moot — a browser session with no cookies has nobody to already be logged in as.
        let (url, state) = try oauth.authorizationURL(
            credentials: credentials,
            forcesLogin: isAddingAnotherAccount
        )
        let callback = try await session.authorize(url: url, isEphemeral: isAddingAnotherAccount)
        let code = try MastodonOAuth.authorizationCode(fromCallback: callback, expectedState: state)
        let token = try await oauth.exchange(code: code, credentials: credentials)

        // Verify before storing: a token that cannot read the account is not worth keeping, and
        // finding that out now gives a far clearer error than a mysteriously empty timeline later.
        let client = MastodonClient(instanceURL: instanceURL, accessToken: token, http: http)
        let account = try await client.verifyCredentials()

        return Result(instanceURL: instanceURL, accessToken: token, account: account)
    }

    /// Stores the access token once the caller has created the `AccountRecord` it belongs to.
    public func persistToken(_ token: String, accountID: UUID) async throws {
        try await keychain.setString(token, for: .mastodonAccessToken, key: accountID.uuidString)
    }
}
