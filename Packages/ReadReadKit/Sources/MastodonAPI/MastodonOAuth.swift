import Foundation
import ReadReadSupport

/// An app registration on one instance.
///
/// Registered per-instance at runtime rather than shipped in the binary. That is the standard
/// Mastodon client pattern and it matters for secrecy: a `client_secret` compiled into a
/// distributed app is public by definition, whereas one minted on the device belongs only to that
/// install and lives in its Keychain.
public struct MastodonClientCredentials: Codable, Sendable {

    public var clientID: String
    public var clientSecret: String

    /// The scopes the registration was created with. Recorded because the authorise step may only
    /// request a subset of them, and a mismatch is rejected by the server.
    public var scopes: String

    public init(clientID: String, clientSecret: String, scopes: String) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.scopes = scopes
    }
}

/// The OAuth flow against one instance.
///
/// Split from `MastodonClient` because it runs unauthenticated, exists only during account setup,
/// and — unlike the rest of the API surface — has to involve the UI. Keeping the browser step
/// behind ``AuthorizationPresenting`` lets the whole exchange be tested without one.
public struct MastodonOAuth: Sendable {

    /// The scopes this app asks for.
    ///
    /// Enumerated one by one rather than asking for the blanket `read`/`write`, so the token can do
    /// exactly what the app has a feature for and nothing else.
    ///
    /// The three `write:` scopes are what favouriting, boosting, replying and muting need, and they
    /// are worth being plain about one at a time:
    ///
    /// - `write:favourites` is exactly favouriting, and nothing else.
    /// - **`write:statuses` covers boosting, and posting, and deleting.** There is no
    ///   `write:reblogs`, so this is the narrowest scope that allows a boost — and the app does now
    ///   post with it: replying to a post is a status written as the reader. Deleting is still
    ///   something the app has no code for, and the scope does not distinguish.
    /// - **`write:mutes` covers muting and unmuting accounts, and also blocking and unblocking
    ///   domains.** There is no narrower scope for a mute. The app only ever calls the mute
    ///   endpoint, and never blocks anything.
    ///
    /// `read:search` is for one thing: resolving a post's URL on a *different* account's instance,
    /// so that "boost as…" can act as an account other than the one whose timeline the post
    /// arrived in. Without it, acting as another account is impossible — that instance has never
    /// heard of the post's local id.
    ///
    /// Changing this string re-registers the app on the instance at the next sign-in, because
    /// `MastodonSignIn` only reuses a stored registration whose scopes match exactly. It does
    /// **not** upgrade a token already granted: an existing account keeps its read-only token
    /// until the reader signs in again, and a write against it fails with
    /// ``MastodonError/writeNotAuthorized``, which the UI turns into a sentence saying so.
    public static let scopes = "read:statuses read:accounts read:lists read:bookmarks read:favourites read:search write:favourites write:statuses write:mutes"

    /// Where the instance sends the user back.
    ///
    /// A custom scheme rather than a universal link: the app has no associated web domain, and
    /// `ASWebAuthenticationSession` matches the scheme itself, so the callback cannot be
    /// intercepted by another app on the device.
    public static let redirectURI = "readread://oauth-callback"

    private let instanceURL: URL
    private let http: HTTPClient

    public init(instanceURL: URL, http: HTTPClient = HTTPClient()) {
        self.instanceURL = instanceURL
        self.http = http
    }

    // MARK: - Step 1: register

    /// Registers the app on the instance.
    public func register(clientName: String = "ReadRead", website: String? = nil) async throws -> MastodonClientCredentials {
        var fields = [
            "client_name": clientName,
            "redirect_uris": Self.redirectURI,
            "scopes": Self.scopes,
        ]
        if let website {
            fields["website"] = website
        }

        var request = URLRequest(url: try MastodonClient.endpoint(
            instanceURL: instanceURL,
            path: "api/v1/apps",
            query: []
        ))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formBody(fields)

        let data = try await http.send(request)
        do {
            let application = try JSONDecoder.mastodon.decode(MastodonApplication.self, from: data)
            return MastodonClientCredentials(
                clientID: application.clientId,
                clientSecret: application.clientSecret,
                scopes: Self.scopes
            )
        } catch let error as DecodingError {
            throw MastodonError.unexpectedResponse(String(describing: error))
        }
    }

    // MARK: - Step 2: authorise

    /// Builds the URL to open in the browser, along with the `state` to verify on return.
    ///
    /// `state` is random per attempt and checked against the callback. Without it, a crafted
    /// callback could hand the app an authorisation code belonging to an account the user did not
    /// choose, and the app would happily exchange it.
    ///
    /// - Parameter forcesLogin: Adds `force_login=true`, which Mastodon documents for exactly one
    ///   situation: authorising a *second* account on an instance the reader is already signed in
    ///   to. Without it the instance behaves reasonably and unhelpfully — there is a live session
    ///   and the app is already authorised for these scopes, so Mastodon's OAuth layer skips both
    ///   the login form and the consent screen and redirects straight back with a code for
    ///   whoever is logged in. From the app's side nothing is shown at all and the code belongs to
    ///   the account it already has, so "add another account" silently adds a duplicate of the
    ///   first one. There is no way to detect that from the callback: it is a valid code for a
    ///   valid account.
    ///
    ///   Not passed by default, because for a first account the skip is the desirable behaviour —
    ///   somebody already signed in to their instance should not be made to type a password to add
    ///   their own feed reader.
    public func authorizationURL(
        credentials: MastodonClientCredentials,
        forcesLogin: Bool = false
    ) throws -> (url: URL, state: String) {
        let state = Self.randomState()
        var query = [
            URLQueryItem(name: "client_id", value: credentials.clientID),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.scopes),
            URLQueryItem(name: "state", value: state),
        ]
        if forcesLogin {
            query.append(URLQueryItem(name: "force_login", value: "true"))
        }
        let url = try MastodonClient.endpoint(instanceURL: instanceURL, path: "oauth/authorize", query: query)
        return (url, state)
    }

    /// Pulls the authorisation code out of the callback URL, verifying `state`.
    public static func authorizationCode(fromCallback url: URL, expectedState: String) throws -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw MastodonError.authorizationFailed("Callback URL could not be parsed")
        }
        let items = components.queryItems ?? []

        // The instance reports refusal as `error`, which is a normal outcome — the user pressed
        // Cancel — and deserves its own message rather than "no code".
        if let error = items.first(where: { $0.name == "error" })?.value {
            let description = items.first { $0.name == "error_description" }?.value
            throw MastodonError.authorizationFailed(description ?? error)
        }

        guard let state = items.first(where: { $0.name == "state" })?.value, state == expectedState else {
            throw MastodonError.authorizationFailed("Authorization state did not match")
        }
        guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw MastodonError.authorizationFailed("Callback contained no authorization code")
        }
        return code
    }

    // MARK: - Step 3: exchange

    /// Exchanges the authorisation code for an access token.
    ///
    /// The code is single-use, so a failure here cannot be retried with the same code — the flow
    /// has to restart from the browser step.
    public func exchange(code: String, credentials: MastodonClientCredentials) async throws -> String {
        var request = URLRequest(url: try MastodonClient.endpoint(
            instanceURL: instanceURL,
            path: "oauth/token",
            query: []
        ))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formBody([
            "grant_type": "authorization_code",
            "client_id": credentials.clientID,
            "client_secret": credentials.clientSecret,
            "redirect_uri": Self.redirectURI,
            "code": code,
            "scope": Self.scopes,
        ])

        let data = try await http.send(request)
        do {
            return try JSONDecoder.mastodon.decode(MastodonTokenResponse.self, from: data).accessToken
        } catch let error as DecodingError {
            throw MastodonError.unexpectedResponse(String(describing: error))
        }
    }

    // MARK: - Helpers

    /// 32 bytes of cryptographically random data, base64url-encoded.
    ///
    /// `SystemRandomNumberGenerator` is the CSPRNG, not `arc4random` or `Int.random(in:)` with a
    /// seeded generator — a guessable `state` defeats the point of having one.
    static func randomState() -> String {
        var generator = SystemRandomNumberGenerator()
        var bytes = [UInt8]()
        bytes.reserveCapacity(32)
        for _ in 0..<32 {
            bytes.append(UInt8.random(in: UInt8.min...UInt8.max, using: &generator))
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Percent-encodes a form body.
    ///
    /// An explicit unreserved set, not `.urlQueryAllowed` — that permits `+`, `&` and `=`, each of
    /// which changes what the server parses. An OAuth secret containing `+` would arrive as a
    /// space and the exchange would fail with a misleading "invalid client" error.
    static func formBody(_ fields: [String: String]) -> Data? {
        let unreserved = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        )
        return fields
            .sorted { $0.key < $1.key }
            .map { key, value in
                let encodedKey = key.addingPercentEncoding(withAllowedCharacters: unreserved) ?? key
                let encodedValue = value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
                return "\(encodedKey)=\(encodedValue)"
            }
            .joined(separator: "&")
            .data(using: .utf8)
    }
}
