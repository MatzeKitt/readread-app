import Foundation

/// The seam between this app and `URLSession`.
///
/// Every network call in the app goes through here, so stubbing this one method is enough to test
/// ingest paging, retry and backoff without a server or a live network.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

extension URLSession: HTTPTransport {

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw HTTPError.notHTTP
        }
        return (data, http)
    }
}

/// A response body together with the parts of the response metadata callers actually need.
///
/// A dedicated value rather than handing back `HTTPURLResponse`: Mastodon paginates through the
/// `Link` header, so headers have to cross the actor boundary, and a small `Sendable` struct is
/// clearer about what is guaranteed to be safe to carry than a Foundation class is.
public struct HTTPReply: Sendable {

    public var data: Data
    public var statusCode: Int

    /// Header fields, keyed as the server sent them.
    public var headers: [String: String]

    public init(data: Data, statusCode: Int, headers: [String: String]) {
        self.data = data
        self.statusCode = statusCode
        self.headers = headers
    }

    /// Looks up a header case-insensitively, as HTTP requires — servers vary on capitalisation and
    /// `Link` in particular shows up both ways.
    public func header(_ name: String) -> String? {
        if let exact = headers[name] { return exact }
        let wanted = name.lowercased()
        return headers.first { $0.key.lowercased() == wanted }?.value
    }
}

public enum HTTPError: Error, Sendable {

    /// A non-2xx response. Carries a decoded prefix of the body, because both FreshRSS and
    /// Mastodon put the actual reason in there and an error that says only "400" is untriageable.
    case status(code: Int, body: String)

    /// The response was not HTTP at all.
    case notHTTP

    /// Retries were exhausted. The last underlying failure is attached.
    case retriesExhausted(underlying: any Error)

    /// The server asked us to slow down for longer than we are willing to wait inline.
    case rateLimited(retryAfter: Duration)

    public var isUnauthorized: Bool {
        if case .status(let code, _) = self { return code == 401 || code == 403 }
        return false
    }

    /// The server understood the request and refused what it said.
    ///
    /// Kept apart from the rest of 4xx because it is the one that means *the content is wrong*
    /// rather than *you are not allowed* or *it is not there* — so it is the only one whose answer
    /// to the reader is "change what you wrote" rather than "sign in again" or "try later".
    public var isUnprocessable: Bool {
        if case .status(let code, _) = self { return code == 422 }
        return false
    }
}

/// How hard to retry.
public struct RetryPolicy: Sendable {

    /// Total attempts, including the first. `1` disables retrying.
    public var maxAttempts: Int

    /// Delay before the second attempt; each subsequent delay doubles.
    public var baseDelay: Duration

    /// Ceiling on any single delay.
    public var maxDelay: Duration

    /// Longest `Retry-After` this client will honour inline. Beyond it the call fails with
    /// ``HTTPError/rateLimited(retryAfter:)`` so the caller can reschedule rather than holding a
    /// request open for minutes.
    public var maxHonouredRetryAfter: Duration

    public init(
        maxAttempts: Int = 3,
        baseDelay: Duration = .milliseconds(500),
        maxDelay: Duration = .seconds(8),
        maxHonouredRetryAfter: Duration = .seconds(30)
    ) {
        self.maxAttempts = maxAttempts
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.maxHonouredRetryAfter = maxHonouredRetryAfter
    }

    public static let `default` = RetryPolicy()

    /// For a background refresh, where the run has a hard deadline and it is better to give up and
    /// resume next time than to spend the whole budget retrying one page.
    public static let impatient = RetryPolicy(maxAttempts: 2, baseDelay: .milliseconds(250), maxDelay: .seconds(2))
}

/// Performs HTTP requests with retry and rate-limit handling.
///
/// An actor so that the jitter generator has a single owner, and so a future connection-level
/// concern (a per-host request cap, say) has an obvious home.
public actor HTTPClient {

    private let transport: any HTTPTransport
    private let policy: RetryPolicy
    private let clock: any Clock<Duration>

    /// - Parameter clock: Injected so tests can advance time instead of waiting through backoff.
    public init(
        transport: any HTTPTransport = URLSession.shared,
        policy: RetryPolicy = .default,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.transport = transport
        self.policy = policy
        self.clock = clock
    }

    /// Sends a request, retrying transient failures.
    ///
    /// Retries only what is actually worth retrying: 5xx, 408, 429 and transport-level errors. A
    /// 4xx is a statement about the request, and repeating it verbatim just wastes the user's
    /// battery and the server's time — with the exception of 429, which is explicitly a "later"
    /// rather than a "no".
    public func send(_ request: URLRequest) async throws -> Data {
        try await reply(for: request).data
    }

    /// Sends a request and returns the body plus response metadata.
    ///
    /// Needed wherever pagination or rate-limit state lives in headers rather than the body.
    public func reply(for request: URLRequest) async throws -> HTTPReply {
        let attempts = max(1, policy.maxAttempts)
        var lastError: (any Error)?

        for attempt in 1...attempts {
            let isLastAttempt = attempt == attempts

            // Only `URLError` is caught here. An `HTTPError` raised below is already a final
            // verdict, and `CancellationError` must never be retried — letting both propagate
            // untouched is what keeps this loop honest.
            do {
                let (data, response) = try await transport.send(request)
                let status = response.statusCode

                if (200..<300).contains(status) {
                    return HTTPReply(
                        data: data,
                        statusCode: status,
                        headers: response.allHeaderFields.reduce(into: [:]) { result, entry in
                            if let key = entry.key as? String, let value = entry.value as? String {
                                result[key] = value
                            }
                        }
                    )
                }

                if status == 429 || status == 503, let retryAfter = Self.retryAfter(from: response) {
                    guard retryAfter <= policy.maxHonouredRetryAfter else {
                        // Holding a request open for minutes is worse than failing and letting the
                        // refresh coordinator reschedule.
                        throw HTTPError.rateLimited(retryAfter: retryAfter)
                    }
                    guard !isLastAttempt else {
                        throw HTTPError.status(code: status, body: Self.bodyPrefix(data))
                    }
                    // An explicit Retry-After overrides our own backoff curve: the server knows
                    // when it will be ready, and guessing shorter just earns another 429.
                    try await clock.sleep(for: retryAfter)
                    continue
                }

                let statusError = HTTPError.status(code: status, body: Self.bodyPrefix(data))
                guard Self.isRetryable(status: status), !isLastAttempt else {
                    throw statusError
                }
                lastError = statusError

            } catch let error as URLError {
                guard Self.isRetryable(urlError: error), !isLastAttempt else {
                    throw error
                }
                lastError = error
            }

            try await clock.sleep(for: delay(forAttempt: attempt))
        }

        throw HTTPError.retriesExhausted(underlying: lastError ?? HTTPError.notHTTP)
    }

    /// Sends a request and decodes JSON from it.
    public func sendJSON<Value: Decodable & Sendable>(
        _ request: URLRequest,
        as type: Value.Type,
        decoder: JSONDecoder = JSONDecoder()
    ) async throws -> Value {
        let data = try await send(request)
        return try decoder.decode(Value.self, from: data)
    }

    /// Sends a request and returns the body as text.
    public func sendText(_ request: URLRequest) async throws -> String {
        let data = try await send(request)
        // FreshRSS's ClientLogin replies in plain UTF-8; `latin1` is the lossless fallback so an
        // unexpected byte cannot turn a successful login into a decode failure.
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
    }

    // MARK: - Backoff

    /// Exponential with full jitter.
    ///
    /// The jitter is not cosmetic: several feeds failing at once would otherwise retry in lockstep
    /// forever, and a server recovering from overload would be hit by the whole herd at the same
    /// instant.
    private func delay(forAttempt attempt: Int) -> Duration {
        // `Duration` only supports integer scaling, so the curve is computed in seconds. The shift
        // is clamped well below the width of `Int` so a long-running retry loop cannot overflow it.
        let exponent = min(max(0, attempt - 1), 16)
        let scaled = policy.baseDelay.seconds * Double(1 << exponent)
        let capped = min(scaled, policy.maxDelay.seconds)
        return .seconds(capped * Double.random(in: 0.5...1.0))
    }

    // MARK: - Classification

    private static func isRetryable(status: Int) -> Bool {
        status == 408 || status == 429 || (500..<600).contains(status)
    }

    private static func isRetryable(urlError: URLError) -> Bool {
        switch urlError.code {
        case .timedOut, .cannotConnectToHost, .networkConnectionLost, .dnsLookupFailed,
             .notConnectedToInternet, .cannotFindHost, .resourceUnavailable,
             .internationalRoamingOff, .callIsActive, .dataNotAllowed, .secureConnectionFailed:
            true
        default:
            // Notably not `.cancelled`, `.userAuthenticationRequired`, `.badURL` or the TLS trust
            // failures: retrying any of those cannot change the outcome.
            false
        }
    }

    /// Parses `Retry-After`, which may be either a delay in seconds or an HTTP date.
    static func retryAfter(from response: HTTPURLResponse) -> Duration? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }

        if let seconds = Double(value) {
            return .seconds(max(0, seconds))
        }

        // Mastodon sends an HTTP date on some rate-limit responses. Parsed by `HTTPDate`, which is
        // where the formats live now that a second caller needs them.
        guard let date = HTTPDate.parse(value) else { return nil }
        return .seconds(max(0, date.timeIntervalSinceNow))
    }

    /// A short, log-safe excerpt of an error body.
    private static func bodyPrefix(_ data: Data, limit: Int = 512) -> String {
        let text = String(data: data.prefix(limit), encoding: .utf8) ?? ""
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public extension Duration {

    /// The duration as fractional seconds.
    ///
    /// `Duration` deliberately offers only integer arithmetic, but backoff curves and jitter are
    /// inherently fractional, so the maths has to happen in `Double` and come back.
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
