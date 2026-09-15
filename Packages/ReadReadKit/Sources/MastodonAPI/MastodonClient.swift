import Foundation
import ReadReadSupport

public enum MastodonError: Error, Sendable {

    case invalidInstanceURL(String)

    /// The instance rejected the token. Mastodon tokens do not expire, so this means revoked —
    /// the user signed the app out from the instance's own settings — and re-authorisation is the
    /// only fix. There is nothing to refresh.
    case tokenRevoked

    /// The body was not the expected JSON, which usually means the host is not a Mastodon-compatible
    /// instance at all.
    case unexpectedResponse(String)

    /// The OAuth callback came back without a code, or with a mismatched `state`.
    case authorizationFailed(String)

    /// The instance accepted the token but refused the write.
    ///
    /// Kept apart from ``tokenRevoked`` because the fix is different and the two arrive as the same
    /// family of status code. A 401 means the token is gone; a 403 on a favourite or a boost almost
    /// always means the token predates this app asking for `write:` scopes, and signing in to the
    /// account again is what fixes it. Reporting that as "revoked" would send the reader looking
    /// for a sign-out they never performed.
    case writeNotAuthorized

    /// The acting instance has never heard of this post.
    ///
    /// Only reachable when acting as an account other than the one the post arrived in: the post
    /// is resolved by URL on the other instance, and an instance that has not federated it — or
    /// that blocks the origin — returns nothing to act on.
    case statusNotFound
}

/// One page of a timeline, plus where to continue.
public struct MastodonTimelinePage: Sendable {

    public var statuses: [MastodonStatus]

    /// The `max_id` to pass for the next (older) page, taken from the `Link` header.
    ///
    /// Nil means the server offered no `next` link, which is how it says there is nothing older.
    public var nextMaxID: String?

    public init(statuses: [MastodonStatus], nextMaxID: String?) {
        self.statuses = statuses
        self.nextMaxID = nextMaxID
    }
}

/// A client for one Mastodon instance.
///
/// An actor because it holds the access token, which is replaced when the user re-authorises.
public actor MastodonClient {

    /// The largest page the API allows for a timeline. Documented as 40; asking for more is
    /// silently clamped, so requesting exactly 40 is what minimises round trips.
    public static let maxTimelineLimit = 40

    private let instanceURL: URL
    private let http: HTTPClient
    private var accessToken: String?

    public init(instanceURL: URL, accessToken: String?, http: HTTPClient = HTTPClient()) {
        self.instanceURL = instanceURL
        self.accessToken = accessToken
        self.http = http
    }

    public func setAccessToken(_ token: String?) {
        accessToken = token
    }

    // MARK: - Endpoints

    /// Confirms the token works and returns who it belongs to.
    public func verifyCredentials() async throws -> MastodonCredentialAccount {
        try await get("api/v1/accounts/verify_credentials", query: [], as: MastodonCredentialAccount.self)
    }

    /// Fetches one page of the home timeline, newest first.
    ///
    /// - Parameter maxID: Return statuses older than this id. Nil starts at the newest.
    public func homeTimeline(
        limit: Int = maxTimelineLimit,
        maxID: String? = nil
    ) async throws -> MastodonTimelinePage {
        var query = [URLQueryItem(name: "limit", value: String(min(limit, Self.maxTimelineLimit)))]
        if let maxID, !maxID.isEmpty {
            query.append(URLQueryItem(name: "max_id", value: maxID))
        }

        let reply = try await authorizedReply(for: try request(path: "api/v1/timelines/home", query: query))

        // A 206 means the home feed is still being regenerated. The body is a valid partial
        // timeline, so it is used — but it must not be treated as the end of the stream, or the
        // walk would stop early and mark the run complete against an incomplete answer.
        let statuses: [MastodonStatus]
        do {
            statuses = try JSONDecoder.mastodon.decode([MastodonStatus].self, from: reply.data)
        } catch let error as DecodingError {
            throw MastodonError.unexpectedResponse(String(describing: error))
        }

        return MastodonTimelinePage(
            statuses: statuses,
            nextMaxID: Self.maxID(fromLinkHeader: reply.header("Link"))
        )
    }

    /// Fetches the conversation a status belongs to.
    ///
    /// `GET /api/v1/statuses/:id/context` returns everything above it (`ancestors`, oldest first)
    /// and everything below (`descendants`). Fetched on demand rather than at ingest, and never
    /// stored: a thread grows after the post is written, so a copy taken during the walk would be
    /// stale by the time anyone opened it — and ingesting one would mean fetching a context per
    /// status, turning a single timeline request into forty.
    ///
    /// The id must be the **displayed** status's, not a boost wrapper's: a boost has no
    /// conversation of its own, and asking for its context returns an empty one.
    public func context(of statusID: MastodonStatusID) async throws -> MastodonStatusContext {
        try await get(
            "api/v1/statuses/\(statusID.rawValue)/context",
            query: [],
            as: MastodonStatusContext.self
        )
    }

    // MARK: - Favouriting and boosting

    /// Favourites a status, or takes it back.
    ///
    /// - Parameter id: The **displayed** status's id, never a boost wrapper's. Acting on the
    ///   wrapper is asking the server to favourite somebody's act of boosting rather than the post
    ///   itself, and what a reader means by liking a boosted post is always the post.
    /// - Returns: The server's updated copy, which carries the authoritative counts and flags. Used
    ///   rather than assuming the outcome, so a row cannot end up showing a state the instance
    ///   disagrees with.
    public func favourite(_ id: MastodonStatusID, isOn: Bool) async throws -> MastodonStatus {
        try await write("api/v1/statuses/\(id.rawValue)/\(isOn ? "favourite" : "unfavourite")")
    }

    /// Boosts a status, or takes the boost back.
    ///
    /// A boost returns the **wrapper** the server just created, whose `reblog` is the post. So the
    /// flags and counts worth reading back come from ``MastodonStatus/displayStatus`` — reading
    /// them off the outer status reports a brand-new boost with no favourites and no boosts, which
    /// would blank the row's counts on success.
    public func reblog(_ id: MastodonStatusID, isOn: Bool) async throws -> MastodonStatus {
        try await write("api/v1/statuses/\(id.rawValue)/\(isOn ? "reblog" : "unreblog")")
    }

    /// Finds the id this instance files a post under, given the post's public URL.
    ///
    /// The step that makes acting as a second account possible at all. A status id is local to the
    /// instance that minted it, so an account on another instance cannot use it — the shared name
    /// for a post across the fediverse is its URL, and `search` with `resolve=true` is how an
    /// instance is asked to go and fetch it if it has not seen it before.
    ///
    /// - Returns: The status as this instance holds it, or nil if it will not resolve one.
    public func resolveStatus(url: URL) async throws -> MastodonStatus? {
        let results = try await get(
            "api/v2/search",
            query: [
                URLQueryItem(name: "q", value: url.absoluteString),
                // Without this the endpoint only searches what the instance already has indexed,
                // which for a post nobody there follows is nothing.
                URLQueryItem(name: "resolve", value: "true"),
                URLQueryItem(name: "type", value: "statuses"),
                URLQueryItem(name: "limit", value: "1"),
            ],
            as: MastodonSearchResults.self
        )
        return results.statuses.first
    }

    // MARK: - Link header

    /// Extracts the `max_id` of the `rel="next"` link.
    ///
    /// The guidelines prefer following the `Link` header over building `max_id` by hand, because
    /// the server knows its own id scheme. Only the `max_id` parameter is kept rather than the
    /// whole URL: the walk has to persist this cursor across app launches, and storing a full
    /// instance-specific URL would break the moment the user's instance changed hostname.
    ///
    /// Format: `<https://host/api/v1/timelines/home?max_id=123>; rel="next", <...>; rel="prev"`
    static func maxID(fromLinkHeader header: String?) -> String? {
        guard let header else { return nil }

        for link in splitLinks(header) {
            guard let openBracket = link.firstIndex(of: "<"),
                  let closeBracket = link.firstIndex(of: ">"),
                  openBracket < closeBracket
            else { continue }

            let parameters = link[link.index(after: closeBracket)...]
            // Match `rel="next"` and the unquoted `rel=next` some proxies rewrite it to.
            guard parameters.contains("rel=\"next\"") || parameters.contains("rel=next") else { continue }

            let urlString = String(link[link.index(after: openBracket)..<closeBracket])
            guard let components = URLComponents(string: urlString) else { continue }
            if let value = components.queryItems?.first(where: { $0.name == "max_id" })?.value, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    /// Splits a `Link` header on the commas that separate entries.
    ///
    /// Not a plain `split(separator: ",")`: a URL may legitimately contain a comma inside its query
    /// string, and splitting there would corrupt the link. Only commas outside `<...>` separate.
    private static func splitLinks(_ header: String) -> [String] {
        var links: [String] = []
        var current = ""
        var insideBrackets = false

        for character in header {
            switch character {
            case "<":
                insideBrackets = true
                current.append(character)
            case ">":
                insideBrackets = false
                current.append(character)
            case "," where !insideBrackets:
                links.append(current)
                current = ""
            default:
                current.append(character)
            }
        }
        if !current.isEmpty { links.append(current) }
        return links
    }

    // MARK: - Request plumbing

    private func get<Value: Decodable & Sendable>(
        _ path: String,
        query: [URLQueryItem],
        as type: Value.Type
    ) async throws -> Value {
        let reply = try await authorizedReply(for: try request(path: path, query: query))
        do {
            return try JSONDecoder.mastodon.decode(Value.self, from: reply.data)
        } catch let error as DecodingError {
            throw MastodonError.unexpectedResponse(String(describing: error))
        }
    }

    /// `POST` to an endpoint that takes no body and answers with a status.
    private func write(_ path: String) async throws -> MastodonStatus {
        var request = try request(path: path, query: [])
        request.httpMethod = "POST"
        // Mastodon's action endpoints take no parameters, but some reverse proxies reject a POST
        // with neither a body nor a length.
        request.setValue("0", forHTTPHeaderField: "Content-Length")

        let reply = try await authorizedReply(for: request, isWrite: true)
        do {
            return try JSONDecoder.mastodon.decode(MastodonStatus.self, from: reply.data)
        } catch let error as DecodingError {
            throw MastodonError.unexpectedResponse(String(describing: error))
        }
    }

    /// - Parameter isWrite: Whether a 403 should be read as a missing scope rather than as a dead
    ///   token. Only a write can be refused for want of a scope in this app — every `read:` scope
    ///   it asks for has been in the set since the first version — so on a read the two are not
    ///   worth telling apart, and conflating them there keeps existing error messages intact.
    private func authorizedReply(for request: URLRequest, isWrite: Bool = false) async throws -> HTTPReply {
        var attempt = request
        if let accessToken {
            attempt.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }

        do {
            return try await http.reply(for: attempt)
        } catch let error as HTTPError where error.isUnauthorized {
            // Deliberately no retry: unlike FreshRSS, there is no credential to re-derive. A
            // Mastodon token is valid until revoked, so a 401 means the user has to authorise
            // again — retrying would just fail identically.
            if isWrite, case .status(let code, _) = error, code == 403 {
                throw MastodonError.writeNotAuthorized
            }
            throw MastodonError.tokenRevoked
        }
    }

    private func request(path: String, query: [URLQueryItem]) throws -> URLRequest {
        URLRequest(url: try Self.endpoint(instanceURL: instanceURL, path: path, query: query))
    }

    /// Builds an endpoint URL, tolerating however the user typed the instance.
    ///
    /// People enter an instance as `mastodon.social`, `@user@mastodon.social`, or with a scheme and
    /// a trailing slash. Normalising here means the account setup screen does not have to.
    static func endpoint(instanceURL: URL, path: String, query: [URLQueryItem]) throws -> URL {
        var base = instanceURL.absoluteString.trimmingCharacters(in: .whitespaces)
        while base.hasSuffix("/") { base.removeLast() }

        guard var components = URLComponents(string: "\(base)/\(path)") else {
            throw MastodonError.invalidInstanceURL(instanceURL.absoluteString)
        }
        if !query.isEmpty {
            components.queryItems = query
        }
        guard let url = components.url else {
            throw MastodonError.invalidInstanceURL(instanceURL.absoluteString)
        }
        return url
    }

    /// Turns whatever the user typed into an instance base URL.
    public static func normalisedInstanceURL(from input: String) -> URL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // Order matters. A full URL already names its host, so the `@` handling applies only to a
        // bare handle — doing it first would turn `https://host/@user` into the host `user`.
        if text.contains("://") {
            while text.hasSuffix("/") { text.removeLast() }
        } else {
            // `@user@host` and `user@host` both name the host after the last `@`.
            if let lastAt = text.lastIndex(of: "@") {
                text = String(text[text.index(after: lastAt)...])
            }
            while text.hasSuffix("/") { text.removeLast() }
            text = "https://\(text)"
        }

        guard let url = URL(string: text), let host = url.host(), host.contains(".") else { return nil }
        // Rebuild from scheme and host alone, discarding any path the user pasted — an instance
        // base URL with a path would silently break every endpoint.
        return URL(string: "https://\(host)")
    }
}
