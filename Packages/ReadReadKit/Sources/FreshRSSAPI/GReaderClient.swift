import Foundation
import ReadReadSupport

/// Which stream to read.
public enum GReaderStream: Sendable, Hashable {

    /// Everything except hidden feeds. The stream ingest walks.
    case readingList

    /// Starred items.
    case starred

    /// A single feed, by its `feed/<n>` id.
    case feed(String)

    /// A category or label, by name.
    case label(String)

    /// The path segment appended to `stream/contents/`, percent-encoded.
    var pathComponent: String {
        switch self {
        case .readingList: "user/-/state/com.google/reading-list"
        case .starred: "user/-/state/com.google/starred"
        case .feed(let id): id
        case .label(let name): "user/-/label/\(name)"
        }
    }

    /// The value for the `s=` parameter, used by `stream/items/ids`.
    var streamID: String { pathComponent }
}

/// Sort direction for a stream walk.
public enum GReaderOrder: String, Sendable {

    /// Newest first. This is descending by *entry id*, which in FreshRSS is a microsecond
    /// insertion timestamp — so it is descending by when items arrived, not by publication date.
    /// That is what makes "walk until the first known id" complete: a newly inserted item always
    /// appears at the top, however old its published date.
    case newestFirst = "d"

    /// Oldest first.
    case oldestFirst = "o"
}

/// Errors specific to the FreshRSS API, distinct from transport failures.
public enum GReaderError: Error, Sendable {

    /// `ClientLogin` succeeded at the HTTP level but the body had no `Auth=` line. In practice this
    /// means the URL points at something that is not a FreshRSS API endpoint.
    case malformedLoginResponse(String)

    /// Credentials rejected. Almost always a missing or wrong **API password** — which is separate
    /// from the web login password and must be set in the FreshRSS profile first.
    case invalidCredentials

    /// The base URL could not be turned into an API URL.
    case invalidServerURL(String)

    /// The server replied with something that is not the expected JSON.
    case unexpectedResponse(String)
}

/// A client for FreshRSS's Google Reader–compatible API.
///
/// An actor because it owns the auth token: the token can be replaced mid-flight when a request
/// comes back 401, and several concurrent ingest sections must not each kick off their own
/// re-login.
public actor GReaderClient {

    /// Credentials for `ClientLogin`.
    public struct Credentials: Sendable {
        public var username: String

        /// The FreshRSS **API password**, not the account password. FreshRSS requires this to be
        /// set separately, and API access stays disabled until it is.
        public var apiPassword: String

        public init(username: String, apiPassword: String) {
            self.username = username
            self.apiPassword = apiPassword
        }
    }

    private let baseURL: URL
    private let http: HTTPClient
    private let credentials: Credentials

    /// The `Auth` value from `ClientLogin`, already in `<user>/<hash>` form.
    private var authToken: String?

    /// In-flight login, so concurrent callers that all see a 401 share one re-login rather than
    /// stampeding the server with duplicate `ClientLogin` requests.
    private var loginTask: Task<String, any Error>?

    public init(baseURL: URL, credentials: Credentials, http: HTTPClient = HTTPClient()) {
        self.baseURL = baseURL
        self.credentials = credentials
        self.http = http
    }

    // MARK: - Authentication

    /// Logs in and caches the token.
    ///
    /// `ClientLogin` responds in `text/plain` with `SID=`, `LSID=` and `Auth=` lines. Only `Auth`
    /// matters, and its value already contains `<user>/<hash>`, so it goes into the header
    /// verbatim.
    public func authenticate() async throws -> String {
        if let authToken { return authToken }

        // Join an existing login rather than starting a second one.
        if let loginTask {
            return try await loginTask.value
        }

        let task = Task<String, any Error> { [baseURL, credentials, http] in
            var request = URLRequest(url: try Self.loginURL(baseURL: baseURL))
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
            // POST, never GET: FreshRSS logs a warning for the GET form precisely because the
            // password ends up in the server's access log.
            request.httpBody = Self.formBody([
                "Email": credentials.username,
                "Passwd": credentials.apiPassword,
            ])

            let body: String
            do {
                body = try await http.sendText(request)
            } catch let error as HTTPError where error.isUnauthorized {
                throw GReaderError.invalidCredentials
            }

            guard let token = Self.authToken(inLoginResponse: body) else {
                throw GReaderError.malformedLoginResponse(String(body.prefix(200)))
            }
            return token
        }

        loginTask = task
        defer { loginTask = nil }

        let token = try await task.value
        authToken = token
        return token
    }

    /// Discards the cached token so the next request logs in again.
    public func invalidateToken() {
        authToken = nil
    }

    /// Extracts the `Auth=` value from a `ClientLogin` body.
    static func authToken(inLoginResponse body: String) -> String? {
        for line in body.split(whereSeparator: \.isNewline) {
            guard let value = line.dropping(prefix: "Auth=") else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            // A server that authenticates but returns `Auth=` empty is malformed, not authorised.
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    // MARK: - Endpoints

    public func userInfo() async throws -> GReaderUserInfo {
        try await get("user-info", query: [], as: GReaderUserInfo.self)
    }

    public func subscriptions() async throws -> [GReaderSubscription] {
        try await get("subscription/list", query: [], as: GReaderSubscriptionList.self).subscriptions
    }

    public func tags() async throws -> [GReaderTag] {
        try await get("tag/list", query: [], as: GReaderTagList.self).tags
    }

    /// Fetches one page of a stream's contents.
    ///
    /// - Parameters:
    ///   - count: Items per page. FreshRSS honours this as `n`.
    ///   - continuation: The `continuation` from the previous page, or `nil` to start at the top.
    ///     It is fed to the server as `c` and applied as an exclusive `id_max`, which is what makes
    ///     a paged walk resumable across app launches.
    ///   - notOlderThan: Bounds how far back the server reaches, sent as `ot`. FreshRSS turns it
    ///     into "published on or after this, **or** modified on or after this", so an old article
    ///     that has just been revised still comes through — which is the behaviour you want from a
    ///     window, and worth knowing because it means `ot` is not purely a date filter.
    public func streamContents(
        _ stream: GReaderStream = .readingList,
        count: Int = 100,
        order: GReaderOrder = .newestFirst,
        continuation: String? = nil,
        excludeTarget: String? = nil,
        notOlderThan: Date? = nil
    ) async throws -> GReaderStreamContents {
        var query = [
            URLQueryItem(name: "output", value: "json"),
            URLQueryItem(name: "n", value: String(count)),
            URLQueryItem(name: "r", value: order.rawValue),
        ]
        if let continuation, !continuation.isEmpty, continuation != "0" {
            query.append(URLQueryItem(name: "c", value: continuation))
        }
        if let excludeTarget {
            query.append(URLQueryItem(name: "xt", value: excludeTarget))
        }
        if let notOlderThan {
            query.append(URLQueryItem(name: "ot", value: String(Int(notOlderThan.timeIntervalSince1970))))
        }

        return try await get(
            "stream/contents/\(stream.pathComponent)",
            query: query,
            as: GReaderStreamContents.self
        )
    }

    /// Fetches one page of a stream's item ids.
    ///
    /// Ids only, so a thousand at a time is cheap. This is what the reconciliation pass diffs
    /// against the local store to find items the server has deleted.
    public func itemIDs(
        _ stream: GReaderStream = .readingList,
        count: Int = 1_000,
        order: GReaderOrder = .newestFirst,
        continuation: String? = nil
    ) async throws -> GReaderItemRefs {
        var query = [
            URLQueryItem(name: "output", value: "json"),
            URLQueryItem(name: "s", value: stream.streamID),
            URLQueryItem(name: "n", value: String(count)),
            URLQueryItem(name: "r", value: order.rawValue),
        ]
        if let continuation, !continuation.isEmpty, continuation != "0" {
            query.append(URLQueryItem(name: "c", value: continuation))
        }

        return try await get("stream/items/ids", query: query, as: GReaderItemRefs.self)
    }

    /// Fetches full items by id.
    ///
    /// `POST` with a repeated `i` parameter, which is what the endpoint requires — it reads `$_POST['i']`
    /// and has no `GET` form.
    public func items(ids: [GReaderItemID]) async throws -> GReaderStreamContents {
        guard !ids.isEmpty else {
            return GReaderStreamContents(id: nil, updated: nil, items: [], continuation: nil)
        }

        let url = try Self.apiURL(baseURL: baseURL, path: "stream/items/contents", query: [
            URLQueryItem(name: "output", value: "json"),
        ])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = ids
            .map { "i=\(Self.escape($0.decimalString))" }
            .joined(separator: "&")
            .data(using: .utf8)

        return try await authorized(request, as: GReaderStreamContents.self)
    }

    // MARK: - Request plumbing

    private func get<Value: Decodable & Sendable>(
        _ path: String,
        query: [URLQueryItem],
        as type: Value.Type
    ) async throws -> Value {
        // Added here rather than left to each caller, because forgetting it is not a soft failure:
        // `greader.php` answers **501 Not Implemented** for any request without `output=json`, and
        // three endpoints — `subscription/list`, `tag/list` and `user-info` — were omitting it.
        // Live FreshRSS could therefore never list a single feed, while every fixture-driven test
        // passed because the stub transport does not check the query.
        var query = query
        if !query.contains(where: { $0.name == "output" }) {
            query.insert(URLQueryItem(name: "output", value: "json"), at: 0)
        }

        let url = try Self.apiURL(baseURL: baseURL, path: path, query: query)
        return try await authorized(URLRequest(url: url), as: type)
    }

    /// Sends a request with the auth header, re-authenticating once on a 401.
    ///
    /// The single retry matters because FreshRSS tokens are derived from the API password hash and
    /// change when the user rotates it — without this, the app would keep failing until relaunch.
    private func authorized<Value: Decodable & Sendable>(
        _ request: URLRequest,
        as type: Value.Type
    ) async throws -> Value {
        var attempt = request
        attempt.setValue("GoogleLogin auth=\(try await authenticate())", forHTTPHeaderField: "Authorization")

        do {
            return try await http.sendJSON(attempt, as: type)
        } catch let error as HTTPError where error.isUnauthorized {
            invalidateToken()
            var retry = request
            retry.setValue("GoogleLogin auth=\(try await authenticate())", forHTTPHeaderField: "Authorization")
            return try await http.sendJSON(retry, as: type)
        } catch let error as DecodingError {
            // A decode failure against this API almost always means the URL resolved to a login
            // page or a reverse proxy error page rather than the API. Saying so is far more useful
            // than surfacing a key-not-found error about JSON the user never saw.
            throw GReaderError.unexpectedResponse(String(describing: error))
        }
    }

    // MARK: - URLs

    /// `<base>/api/greader.php/accounts/ClientLogin`
    static func loginURL(baseURL: URL) throws -> URL {
        try endpointURL(baseURL: baseURL, suffix: "accounts/ClientLogin", query: [])
    }

    /// `<base>/api/greader.php/reader/api/0/<path>`
    static func apiURL(baseURL: URL, path: String, query: [URLQueryItem]) throws -> URL {
        try endpointURL(baseURL: baseURL, suffix: "reader/api/0/\(path)", query: query)
    }

    private static func endpointURL(baseURL: URL, suffix: String, query: [URLQueryItem]) throws -> URL {
        // Accept the base URL however the user typed it — with or without a trailing slash, and
        // with or without `/api/greader.php` already on the end. Pasting the URL straight out of
        // the FreshRSS profile page is the common case and it already includes `/api/`.
        var base = baseURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }

        for tail in ["/api/greader.php", "/api"] where base.hasSuffix(tail) {
            base.removeLast(tail.count)
            break
        }

        guard var components = URLComponents(string: "\(base)/api/greader.php/\(suffix)") else {
            throw GReaderError.invalidServerURL(baseURL.absoluteString)
        }
        if !query.isEmpty {
            components.queryItems = query
        }
        guard let url = components.url else {
            throw GReaderError.invalidServerURL(baseURL.absoluteString)
        }
        return url
    }

    private static func formBody(_ fields: [String: String]) -> Data? {
        fields
            .map { "\(escape($0.key))=\(escape($0.value))" }
            .joined(separator: "&")
            .data(using: .utf8)
    }

    /// Percent-encodes a form value.
    ///
    /// An explicit allowed set rather than `.urlQueryAllowed`, which permits `+`, `&` and `=` —
    /// all of which change the meaning of a form body. A password containing `+` would otherwise
    /// be silently received as a space.
    private static func escape(_ value: String) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }
}

private extension StringProtocol {

    func dropping(prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count))
    }
}
