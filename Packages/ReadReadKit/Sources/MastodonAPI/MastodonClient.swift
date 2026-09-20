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

    /// The instance understood the request and refused what it said.
    ///
    /// A 422, which for a post means the instance's own rules: over its character limit, an empty
    /// body, a visibility it does not allow, a poll it will not accept. Distinct from
    /// ``writeNotAuthorized`` because nothing about signing in again would help — the reader has to
    /// change what they wrote.
    case rejected
}

/// How widely a post is shown.
///
/// Its own type rather than the raw string, because the one rule worth enforcing is a comparison
/// between two of them: **a reply must never be more visible than the post it answers.** Replying
/// publicly to a followers-only post republishes the fact that the post exists, to an audience its
/// author deliberately excluded — and the reply quotes it by being attached to it.
public enum MastodonVisibility: String, Codable, Sendable, CaseIterable {

    /// Public timelines, anywhere.
    case `public`

    /// Visible to anyone with the link, but kept out of the public timelines.
    case unlisted

    /// Followers only.
    case `private`

    /// Only the people mentioned.
    case direct

    /// How far this reaches, for comparison only. Larger is wider.
    ///
    /// Not `Comparable`: the numbers are an ordering of audiences, not a scale, and nothing should
    /// be tempted to do arithmetic on them.
    var reach: Int {
        switch self {
        case .public: 3
        case .unlisted: 2
        case .private: 1
        case .direct: 0
        }
    }

    /// What a reply to a post of this visibility may be sent as.
    ///
    /// Ordered widest first, so the picker reads the way the composer's own default sits at the
    /// top. The parent's own visibility is always in the list, so there is always something to
    /// choose — and it is always the default; see ``defaultForReply(to:)``.
    public static func allowedForReply(to parent: MastodonVisibility) -> [MastodonVisibility] {
        allCases
            .filter { $0.reach <= parent.reach }
            .sorted { $0.reach > $1.reach }
    }

    /// What a reply starts out as.
    ///
    /// The parent's own visibility, which is both the safe answer and the expected one: answering a
    /// followers-only post should stay among followers without the reader having to notice, and
    /// answering a public post publicly is what a public conversation is.
    public static func defaultForReply(to parent: MastodonVisibility) -> MastodonVisibility {
        parent
    }

    /// Reads a status's `visibility` string, defaulting to the narrowest sensible answer.
    ///
    /// An unknown value defaults to ``private`` rather than to `public`, because a visibility this
    /// build does not recognise is one an instance has added — and guessing wide on something
    /// unknown is how a reply escapes the audience its parent had.
    public init(statusValue: String) {
        self = MastodonVisibility(rawValue: statusValue) ?? .private
    }
}

/// How the acting account stands towards another account.
///
/// Only the fields this app acts on. The endpoint returns a great deal more — following, blocking,
/// notes, domain blocks — and decoding what is never read would make the type look like a surface
/// the app has, which it does not.
public struct MastodonRelationship: Codable, Sendable {

    public let id: String

    /// Documented as always present; optional so an instance that omits it cannot fail the decode
    /// of a request that otherwise succeeded.
    public let muting: Bool?
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

    // MARK: - Muting

    /// Stops an account's posts reaching this account's home timeline.
    ///
    /// `notifications: true` — the endpoint's own default — so muting also silences the person's
    /// replies and mentions. A mute that left notifications coming through would not be the thing
    /// the word means to anyone using it, and the reader who reached for it would have to find the
    /// second switch themselves.
    ///
    /// No duration is sent, so the mute is indefinite. Mastodon's `duration` is for temporary
    /// mutes, and offering a timer in a context menu is a different feature from the one this is.
    ///
    /// - Parameter accountID: The account's id **on this instance**. Ids are minted per instance,
    ///   so this is only ever the id the acting account's own server knows the person by — which is
    ///   the reason ``StatusInteractions`` only ever mutes as the account a post arrived in.
    public func mute(_ accountID: String, notifications: Bool = true) async throws -> MastodonRelationship {
        var request = try request(path: "api/v1/accounts/\(accountID)/mute", query: [])
        request.httpMethod = "POST"
        Self.setForm(["notifications": notifications ? "true" : "false"], on: &request)

        let reply = try await authorizedReply(for: request, isWrite: true)
        do {
            return try JSONDecoder.mastodon.decode(MastodonRelationship.self, from: reply.data)
        } catch let error as DecodingError {
            throw MastodonError.unexpectedResponse(String(describing: error))
        }
    }

    // MARK: - Posting

    /// Posts a status, optionally as a reply to another.
    ///
    /// - Parameter idempotencyKey: Sent as `Idempotency-Key`, and not optional on purpose. A reply
    ///   is the one request in this app where a retry is genuinely dangerous: `HTTPClient` retries a
    ///   5xx, and a gateway that times out *after* the instance accepted the post would otherwise
    ///   produce the post twice, publicly, with no way to tell it happened. Mastodon collapses
    ///   repeats of the same key onto the first post for some hours, which turns that into a no-op.
    ///   The key must therefore be derived from the draft and stay the same across retries — never
    ///   generated per attempt.
    /// - Parameter spoilerText: The content warning. Empty means none; the field is only sent when
    ///   it has something in it, because sending `spoiler_text=` empty marks some instances' posts
    ///   as warned with a blank warning.
    public func postStatus(
        _ text: String,
        inReplyTo: MastodonStatusID? = nil,
        visibility: MastodonVisibility,
        spoilerText: String = "",
        idempotencyKey: String
    ) async throws -> MastodonStatus {
        var fields = [
            "status": text,
            "visibility": visibility.rawValue,
        ]
        if let inReplyTo {
            fields["in_reply_to_id"] = inReplyTo.rawValue
        }
        let warning = spoilerText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !warning.isEmpty {
            fields["spoiler_text"] = warning
        }

        var request = try request(path: "api/v1/statuses", query: [])
        request.httpMethod = "POST"
        request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        Self.setForm(fields, on: &request)

        do {
            let reply = try await authorizedReply(for: request, isWrite: true)
            do {
                return try JSONDecoder.mastodon.decode(MastodonStatus.self, from: reply.data)
            } catch let error as DecodingError {
                throw MastodonError.unexpectedResponse(String(describing: error))
            }
        } catch let error as HTTPError where error.isUnprocessable {
            // The instance read it and said no — over its character limit, or a visibility it does
            // not offer. Its own explanation is in the body and is deliberately not carried out of
            // here: an `HTTPError` holds the request, whose header holds the token.
            throw MastodonError.rejected
        }
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

    /// Attaches a form-encoded body, and the header that says so.
    ///
    /// Form-encoded rather than JSON because that is what the Mastodon API documents for these
    /// endpoints, and what every instance and every reverse proxy in front of one is certain to
    /// accept. `Content-Length` comes along with it for the same reason ``write(_:)`` sets one.
    ///
    /// Percent-encoding against an explicit unreserved set rather than `.urlQueryAllowed`, which
    /// permits `&`, `=` and `+` through — so a post containing any of them would be read back by
    /// the instance as extra form fields, or have its pluses turned into spaces. A reply is free
    /// text written by a person, so it contains those characters routinely.
    static func setForm(_ fields: [String: String], on request: inout URLRequest) {
        let unreserved = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        )
        let body = fields
            // Sorted so the body is a function of the fields alone: an idempotency key covers a
            // repeat of the same post, and a test asserting on a body cannot assert on a dictionary
            // ordering that changes per launch.
            .sorted { $0.key < $1.key }
            .map { key, value in
                let encodedKey = key.addingPercentEncoding(withAllowedCharacters: unreserved) ?? key
                let encodedValue = value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
                return "\(encodedKey)=\(encodedValue)"
            }
            .joined(separator: "&")
            .data(using: .utf8) ?? Data()

        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
        request.httpBody = body
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
