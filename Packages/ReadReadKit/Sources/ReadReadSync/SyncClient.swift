import Foundation
import ReadReadModel
import ReadReadSupport

/// Where to reach the sync endpoint, and with what token.
public struct SyncConfiguration: Sendable, Equatable {

    public var baseURL: URL

    /// The long-lived bearer token minted by `readread-sync token:create`.
    public var token: String

    public init(baseURL: URL, token: String) {
        self.baseURL = baseURL
        self.token = token
    }
}

/// Talks to the self-hosted sync endpoint.
///
/// Thin on purpose. All the merge policy lives in ``SyncStore``, because the server is a dumb blob
/// store and this type should not be the place where domain decisions accidentally accumulate.
public actor SyncClient {

    private let http: HTTPClient
    private var configuration: SyncConfiguration?

    public init(configuration: SyncConfiguration? = nil, http: HTTPClient = HTTPClient()) {
        self.configuration = configuration
        self.http = http
    }

    public func configure(_ configuration: SyncConfiguration?) {
        self.configuration = configuration
    }

    public var isConfigured: Bool { configuration != nil }

    // MARK: - Endpoints

    /// Checks the endpoint is reachable and is actually the sync service.
    ///
    /// Unauthenticated, so account setup can validate the URL before the user has pasted a token —
    /// which makes "wrong URL" and "wrong token" two distinct, diagnosable failures instead of one
    /// confusing 401.
    public func health() async throws -> SyncHealth {
        let url = try Self.endpoint(baseURL: try requireConfiguration().baseURL, path: "health", query: [])
        return try await decode(SyncHealth.self, from: URLRequest(url: url), authorized: false)
    }

    /// Fetches one page of changes newer than `since`.
    public func pull(since: Int, limit: Int = 500) async throws -> SyncChangesPage {
        let url = try Self.endpoint(
            baseURL: try requireConfiguration().baseURL,
            path: "changes",
            query: [
                URLQueryItem(name: "since", value: String(max(0, since))),
                URLQueryItem(name: "limit", value: String(limit)),
            ]
        )
        return try await decode(SyncChangesPage.self, from: URLRequest(url: url), authorized: true)
    }

    /// Pushes a batch of records.
    public func push(_ records: [SyncPushRecord]) async throws -> SyncPushResult {
        guard !records.isEmpty else {
            return SyncPushResult(applied: [], maxRevision: 0)
        }

        let url = try Self.endpoint(baseURL: try requireConfiguration().baseURL, path: "changes", query: [])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(SyncPushBody(records: records))

        return try await decode(SyncPushResult.self, from: request, authorized: true)
    }

    private struct SyncPushBody: Encodable {
        var records: [SyncPushRecord]
    }

    // MARK: - Plumbing

    private func requireConfiguration() throws -> SyncConfiguration {
        guard let configuration else { throw SyncError.notConfigured }
        return configuration
    }

    private func decode<Value: Decodable & Sendable>(
        _ type: Value.Type,
        from request: URLRequest,
        authorized: Bool
    ) async throws -> Value {
        var attempt = request
        if authorized {
            attempt.setValue("Bearer \(try requireConfiguration().token)", forHTTPHeaderField: "Authorization")
        }

        let data: Data
        do {
            data = try await http.send(attempt)
        } catch let error as HTTPError {
            throw Self.translate(error)
        }

        do {
            return try JSONDecoder().decode(Value.self, from: data)
        } catch let error as SyncError {
            throw error
        } catch {
            throw SyncError.unexpectedResponse(String(describing: error))
        }
    }

    /// Turns transport failures into terms the sync layer can act on.
    ///
    /// A 400 is separated from a 500 because they need opposite responses: a rejected record is a
    /// client bug that will fail identically forever, so it must be dropped from the outbox rather
    /// than retried, while a 500 is worth retrying.
    static func translate(_ error: HTTPError) -> any Error {
        guard case .status(let code, let body) = error else { return error }

        if code == 401 || code == 403 {
            return SyncError.unauthorized
        }
        if code == 400 || code == 413 {
            return SyncError.rejected(Self.message(fromErrorBody: body) ?? body)
        }
        return error
    }

    /// Pulls the `message` field out of the service's error body.
    static func message(fromErrorBody body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = object["message"] as? String
        else { return nil }
        return message
    }

    /// Builds an endpoint URL under `/api/v1/`.
    ///
    /// Tolerates the base URL being given with or without a trailing slash and with or without the
    /// `/api/v1` suffix already present, because the README shows it both ways and pasting either
    /// should work.
    static func endpoint(baseURL: URL, path: String, query: [URLQueryItem]) throws -> URL {
        var base = baseURL.absoluteString.trimmingCharacters(in: .whitespaces)
        while base.hasSuffix("/") { base.removeLast() }

        for suffix in ["/api/v1", "/api"] where base.hasSuffix(suffix) {
            base.removeLast(suffix.count)
            break
        }

        guard var components = URLComponents(string: "\(base)/api/v1/\(path)") else {
            throw SyncError.invalidServerURL(baseURL.absoluteString)
        }
        if !query.isEmpty {
            components.queryItems = query
        }
        guard let url = components.url else {
            throw SyncError.invalidServerURL(baseURL.absoluteString)
        }
        return url
    }
}
