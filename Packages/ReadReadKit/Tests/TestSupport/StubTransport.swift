import Foundation
import ReadReadSupport

/// A scripted `HTTPTransport` for tests.
///
/// Lets a test describe a whole sequence of server responses — including failures, rate limits and
/// paged bodies — and then assert on exactly which requests were made. That is what makes it
/// possible to test a resumable paging walk deterministically: the interesting bugs are about
/// *which* requests happen after an interruption, which no live server can be made to reproduce
/// on demand.
public actor StubTransport: HTTPTransport {

    /// One scripted outcome.
    public enum Response: Sendable {
        case ok(Data)
        case json(String)
        case text(String)
        case status(Int, body: String = "")
        case statusWithHeaders(Int, headers: [String: String], body: String = "")
        case failure(URLError.Code)
    }

    /// Requests seen so far, in order.
    public private(set) var requests: [URLRequest] = []

    private var scripted: [Response]

    /// Returned once `scripted` runs out. Nil means an unscripted request is a test failure.
    private var fallback: Response?

    public init(_ responses: [Response] = [], fallback: Response? = nil) {
        scripted = responses
        self.fallback = fallback
    }

    /// Convenience for the common single-response case.
    public init(_ response: Response) {
        scripted = [response]
        fallback = nil
    }

    public func enqueue(_ responses: Response...) {
        scripted.append(contentsOf: responses)
    }

    public func setFallback(_ response: Response?) {
        fallback = response
    }

    // MARK: - Inspection

    public var requestCount: Int { requests.count }

    public var urls: [String] {
        requests.compactMap { $0.url?.absoluteString }
    }

    /// Query parameters of the request at `index`, flattened for easy assertions.
    public func queryItems(at index: Int) -> [String: String] {
        guard requests.indices.contains(index),
              let url = requests[index].url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return [:] }
        return Dictionary(
            (components.queryItems ?? []).map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { _, last in last }
        )
    }

    public func body(at index: Int) -> String {
        guard requests.indices.contains(index), let data = requests[index].httpBody else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    public func header(_ name: String, at index: Int) -> String? {
        guard requests.indices.contains(index) else { return nil }
        return requests[index].value(forHTTPHeaderField: name)
    }

    // MARK: - HTTPTransport

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)

        let response: Response
        if !scripted.isEmpty {
            response = scripted.removeFirst()
        } else if let fallback {
            response = fallback
        } else {
            // Surfaced as a transport error so it fails the test loudly rather than looking like
            // an empty page, which a paging walk would happily treat as "end of stream".
            throw StubTransportError.unscriptedRequest(request.url?.absoluteString ?? "?")
        }

        let url = request.url ?? URL(string: "https://example.invalid")!

        switch response {
        case .ok(let data):
            return (data, Self.http(url: url, status: 200, headers: [:]))
        case .json(let json):
            return (Data(json.utf8), Self.http(url: url, status: 200, headers: ["Content-Type": "application/json"]))
        case .text(let text):
            return (Data(text.utf8), Self.http(url: url, status: 200, headers: ["Content-Type": "text/plain"]))
        case .status(let code, let body):
            return (Data(body.utf8), Self.http(url: url, status: code, headers: [:]))
        case .statusWithHeaders(let code, let headers, let body):
            return (Data(body.utf8), Self.http(url: url, status: code, headers: headers))
        case .failure(let code):
            throw URLError(code)
        }
    }

    private static func http(url: URL, status: Int, headers: [String: String]) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    }
}

public enum StubTransportError: Error, Sendable {
    /// The code under test made a request the test did not script.
    case unscriptedRequest(String)
}
