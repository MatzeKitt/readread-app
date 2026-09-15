import Foundation
import ReadReadTestSupport
import Testing

@testable import ReadReadSupport

@Suite("HTTPClient")
struct HTTPClientTests {

    private func makeClient(
        _ transport: StubTransport,
        policy: RetryPolicy = RetryPolicy(maxAttempts: 3, baseDelay: .seconds(1), maxDelay: .seconds(8))
    ) -> (HTTPClient, TestClock) {
        let clock = TestClock()
        return (HTTPClient(transport: transport, policy: policy, clock: clock), clock)
    }

    private let request = URLRequest(url: URL(string: "https://rss.example.net/api")!)

    @Test("A 200 returns the body without sleeping")
    func successReturnsBody() async throws {
        let transport = StubTransport(.text("hello"))
        let (client, clock) = makeClient(transport)

        let data = try await client.send(request)

        #expect(String(data: data, encoding: .utf8) == "hello")
        #expect(await transport.requestCount == 1)
        #expect(clock.sleepCount == 0)
    }

    /// Repeating a 4xx verbatim cannot change the outcome; it only costs the user battery and the
    /// server load.
    @Test("Client errors are not retried", arguments: [400, 401, 403, 404, 422])
    func clientErrorsAreNotRetried(status: Int) async throws {
        let transport = StubTransport(.status(status, body: "nope"))
        let (client, _) = makeClient(transport)

        await #expect(throws: HTTPError.self) {
            _ = try await client.send(request)
        }
        #expect(await transport.requestCount == 1)
    }

    @Test("Server errors are retried up to the attempt limit", arguments: [500, 502, 503, 504, 408])
    func serverErrorsAreRetried(status: Int) async throws {
        let transport = StubTransport([], fallback: .status(status))
        let (client, _) = makeClient(transport)

        await #expect(throws: HTTPError.self) {
            _ = try await client.send(request)
        }
        #expect(await transport.requestCount == 3)
    }

    @Test("A retry that succeeds returns the later body")
    func retryEventuallySucceeds() async throws {
        let transport = StubTransport([.status(503), .status(500), .text("third time")])
        let (client, clock) = makeClient(transport)

        let data = try await client.send(request)

        #expect(String(data: data, encoding: .utf8) == "third time")
        #expect(await transport.requestCount == 3)
        #expect(clock.sleepCount == 2)
    }

    /// Without jitter, a batch of feeds failing together would retry in lockstep forever and hit a
    /// recovering server as one herd. The curve must still be recognisably exponential.
    @Test("Backoff grows exponentially and stays jittered within bounds")
    func backoffIsExponentialAndJittered() async throws {
        let transport = StubTransport([], fallback: .status(500))
        let clock = TestClock()
        let client = HTTPClient(
            transport: transport,
            policy: RetryPolicy(maxAttempts: 5, baseDelay: .seconds(1), maxDelay: .seconds(30)),
            clock: clock
        )

        _ = try? await client.send(request)

        let sleeps = clock.sleeps.map(\.seconds)
        #expect(sleeps.count == 4)
        // Each window is [0.5, 1.0] × 2^(n-1), so the bands do not overlap and ordering is
        // guaranteed despite the randomness.
        for (index, slept) in sleeps.enumerated() {
            let ceiling = pow(2.0, Double(index))
            #expect(slept >= ceiling * 0.5, "attempt \(index + 1) slept \(slept)")
            #expect(slept <= ceiling, "attempt \(index + 1) slept \(slept)")
        }
    }

    @Test("Backoff is capped")
    func backoffIsCapped() async throws {
        let transport = StubTransport([], fallback: .status(500))
        let clock = TestClock()
        let client = HTTPClient(
            transport: transport,
            policy: RetryPolicy(maxAttempts: 6, baseDelay: .seconds(1), maxDelay: .seconds(2)),
            clock: clock
        )

        _ = try? await client.send(request)

        #expect(clock.sleeps.allSatisfy { $0.seconds <= 2.0 })
    }

    // MARK: - Rate limiting

    /// A 429 is a "later", not a "no", and the server's own number beats our guess — undercutting
    /// it just earns another 429.
    @Test("Retry-After in seconds is honoured exactly, overriding the backoff curve")
    func retryAfterSecondsIsHonoured() async throws {
        let transport = StubTransport([
            .statusWithHeaders(429, headers: ["Retry-After": "7"]),
            .text("ok"),
        ])
        let (client, clock) = makeClient(transport)

        _ = try await client.send(request)

        #expect(clock.sleeps == [.seconds(7)])
    }

    @Test("Retry-After as an HTTP date is honoured")
    func retryAfterHTTPDateIsHonoured() async throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let future = formatter.string(from: Date().addingTimeInterval(5))

        let transport = StubTransport([
            .statusWithHeaders(503, headers: ["Retry-After": future]),
            .text("ok"),
        ])
        let (client, clock) = makeClient(transport)

        _ = try await client.send(request)

        #expect(clock.sleepCount == 1)
        // Allow slack for the second that may tick over between formatting and parsing.
        #expect(clock.sleeps[0].seconds > 3 && clock.sleeps[0].seconds <= 5)
    }

    /// Holding a request open for minutes is worse than failing: the refresh coordinator can
    /// reschedule, and on iOS the background budget would expire anyway.
    @Test("A Retry-After longer than we will wait fails instead of blocking")
    func excessiveRetryAfterFailsFast() async throws {
        let transport = StubTransport(.statusWithHeaders(429, headers: ["Retry-After": "600"]))
        let clock = TestClock()
        let client = HTTPClient(
            transport: transport,
            policy: RetryPolicy(maxAttempts: 3, maxHonouredRetryAfter: .seconds(30)),
            clock: clock
        )

        await #expect(throws: HTTPError.self) {
            _ = try await client.send(request)
        }
        #expect(await transport.requestCount == 1)
        #expect(clock.sleepCount == 0)
    }

    @Test("A 429 without Retry-After still uses the backoff curve")
    func rateLimitWithoutHeaderUsesBackoff() async throws {
        let transport = StubTransport([.status(429), .text("ok")])
        let (client, clock) = makeClient(transport)

        _ = try await client.send(request)

        #expect(clock.sleepCount == 1)
    }

    // MARK: - Transport failures

    @Test("Transient transport errors are retried", arguments: [
        URLError.Code.timedOut,
        .networkConnectionLost,
        .cannotConnectToHost,
        .dnsLookupFailed,
        .notConnectedToInternet,
    ])
    func transientTransportErrorsAreRetried(code: URLError.Code) async throws {
        let transport = StubTransport([.failure(code), .text("recovered")])
        let (client, _) = makeClient(transport)

        let data = try await client.send(request)

        #expect(String(data: data, encoding: .utf8) == "recovered")
        #expect(await transport.requestCount == 2)
    }

    /// Retrying these cannot change the outcome, and retrying a cancellation actively fights the
    /// caller that asked to stop.
    @Test("Permanent transport errors are not retried", arguments: [
        URLError.Code.badURL,
        .cancelled,
        .unsupportedURL,
        .userAuthenticationRequired,
    ])
    func permanentTransportErrorsAreNotRetried(code: URLError.Code) async throws {
        let transport = StubTransport(.failure(code))
        let (client, _) = makeClient(transport)

        await #expect(throws: URLError.self) {
            _ = try await client.send(request)
        }
        #expect(await transport.requestCount == 1)
    }

    @Test("maxAttempts of 1 disables retrying")
    func singleAttemptDisablesRetry() async throws {
        let transport = StubTransport([], fallback: .status(500))
        let (client, clock) = makeClient(transport, policy: RetryPolicy(maxAttempts: 1))

        await #expect(throws: HTTPError.self) {
            _ = try await client.send(request)
        }
        #expect(await transport.requestCount == 1)
        #expect(clock.sleepCount == 0)
    }

    // MARK: - Decoding helpers

    @Test("sendJSON decodes the body")
    func sendJSONDecodes() async throws {
        struct Payload: Decodable, Sendable { let value: Int }
        let transport = StubTransport(.json(#"{"value":42}"#))
        let (client, _) = makeClient(transport)

        let payload = try await client.sendJSON(request, as: Payload.self)

        #expect(payload.value == 42)
    }

    @Test("Error bodies are attached to the thrown status")
    func errorBodyIsAttached() async throws {
        let transport = StubTransport(.status(400, body: "API password not set"))
        let (client, _) = makeClient(transport)

        do {
            _ = try await client.send(request)
            Issue.record("expected a failure")
        } catch let error as HTTPError {
            guard case .status(let code, let body) = error else {
                Issue.record("expected .status, got \(error)")
                return
            }
            #expect(code == 400)
            // A bare "400" is untriageable; both servers put the real reason in the body.
            #expect(body == "API password not set")
        }
    }

    @Test("isUnauthorized recognises the statuses that mean re-authenticate")
    func recognisesUnauthorized() {
        #expect(HTTPError.status(code: 401, body: "").isUnauthorized)
        #expect(HTTPError.status(code: 403, body: "").isUnauthorized)
        #expect(!HTTPError.status(code: 500, body: "").isUnauthorized)
        #expect(!HTTPError.notHTTP.isUnauthorized)
    }

    @Test("Retry-After parsing", arguments: [
        ("5", 5.0),
        ("0", 0.0),
        (" 12 ", 12.0),
    ])
    func parsesRetryAfterSeconds(header: String, expected: Double) {
        let response = HTTPURLResponse(
            url: URL(string: "https://example.com")!,
            statusCode: 429,
            httpVersion: nil,
            headerFields: ["Retry-After": header]
        )!

        #expect(HTTPClient.retryAfter(from: response)?.seconds == expected)
    }

    @Test("An absent or unparseable Retry-After yields nil", arguments: ["", "soon", "next tuesday"])
    func unparseableRetryAfterIsNil(header: String) {
        let response = HTTPURLResponse(
            url: URL(string: "https://example.com")!,
            statusCode: 429,
            httpVersion: nil,
            headerFields: header.isEmpty ? [:] : ["Retry-After": header]
        )!

        #expect(HTTPClient.retryAfter(from: response) == nil)
    }
}
