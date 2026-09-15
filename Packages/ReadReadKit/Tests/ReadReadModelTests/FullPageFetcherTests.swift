import Foundation
import ReadReadSupport
import ReadReadTestSupport
import Testing

@testable import ReadReadModel

@Suite("FullPageFetcher")
struct FullPageFetcherTests {

    private let url = URL(string: "https://example.com/posts/widgets")!

    private var articlePage: String {
        let body = (1...6).map { index in
            "<p>Paragraph \(index) about widgets, their manufacture, and the people who make them, "
                + "at a length that reads like prose rather than like a caption.</p>"
        }.joined()

        return """
        <!doctype html><html><head><title>Widgets</title></head>
        <body><nav><a href="/">Home</a></nav>
        <article class="post-content">\(body)</article>
        <footer><p>Copyright, all rights reserved, everywhere, forever.</p></footer>
        </body></html>
        """
    }

    private func html(_ body: String, contentType: String = "text/html; charset=utf-8") -> StubTransport.Response {
        .statusWithHeaders(200, headers: ["Content-Type": contentType], body: body)
    }

    @Test("A page with an article yields the extracted body")
    func extractsArticle() async throws {
        let transport = StubTransport(html(articlePage))
        let outcome = try await FullPageFetcher(transport: transport).fetch(url)

        guard case .extracted(let html, let length) = outcome else {
            Issue.record("expected an extraction, got \(outcome)")
            return
        }
        #expect(html.contains("Paragraph 1 about widgets"))
        #expect(!html.contains("Copyright"))
        #expect(length > 400)
    }

    @Test("A page with no article is unusable rather than an error")
    func clientRenderedPageIsUnusable() async throws {
        let transport = StubTransport(html("<html><body><div id=\"root\"></div></body></html>"))
        let outcome = try await FullPageFetcher(transport: transport).fetch(url)

        // The distinction the caller depends on: unusable is cached and never retried, an error is
        // not cached and may succeed next time.
        #expect(outcome == .unusable)
    }

    @Test("The request identifies the app and carries no cookies")
    func requestShape() async throws {
        let transport = StubTransport(html(articlePage))
        _ = try await FullPageFetcher(transport: transport).fetch(url)

        let agent = await transport.header("User-Agent", at: 0) ?? ""
        #expect(agent.contains("ReadRead"))
        // Not a browser: impersonating one to get past blocks is not this app's business.
        #expect(!agent.contains("Mozilla"))

        let request = await transport.requests[0]
        // Cookies set by one article fetch would be sent back on the next, which is exactly the
        // cross-article profile extraction is meant not to feed.
        #expect(request.httpShouldHandleCookies == false)
    }

    @Test("Something that is not a web page is rejected before it is parsed")
    func rejectsNonMarkup() async throws {
        let transport = StubTransport(html("%PDF-1.4", contentType: "application/pdf"))

        await #expect(throws: FullPageFetcher.Failure.notAWebPage(contentType: "application/pdf")) {
            try await FullPageFetcher(transport: transport).fetch(url)
        }
    }

    @Test("A missing Content-Type is treated as markup")
    func missingContentTypeIsAllowed() async throws {
        // A misconfigured server is not evidence that the body is something else, and the
        // extractor fails safely on anything it is not.
        let transport = StubTransport(.ok(Data(articlePage.utf8)))
        let outcome = try await FullPageFetcher(transport: transport).fetch(url)

        guard case .extracted = outcome else {
            Issue.record("expected an extraction, got \(outcome)")
            return
        }
    }

    @Test("A page in a legacy encoding is decoded, not dropped")
    func decodesDeclaredCharset() throws {
        // The feeds most likely to publish truncated summaries are often the oldest ones, and a
        // Windows-1252 page decoded as UTF-8 fails outright rather than degrading.
        let text = "Ärger mit Übersetzungen — für alle."
        let data = try #require(text.data(using: .windowsCP1252))

        #expect(FullPageFetcher.decode(data, contentType: "text/html; charset=windows-1252") == text)
    }

    @Test("An undeclared UTF-8 page is decoded as UTF-8")
    func decodesUndeclaredUTF8() throws {
        let text = "Ärger mit Übersetzungen — für alle."
        #expect(FullPageFetcher.decode(Data(text.utf8), contentType: "text/html") == text)
    }

    @Test("A charset declared only in a meta tag is honoured")
    func decodesMetaCharset() throws {
        let page = "<html><head><meta charset=\"iso-8859-1\"></head><body>Café Ärger</body></html>"
        let data = try #require(page.data(using: .isoLatin1))

        let decoded = try #require(FullPageFetcher.decode(data, contentType: "text/html"))
        #expect(decoded.contains("Café Ärger"))
    }

    @Test("A body larger than the cap is refused")
    func refusesOversizedBodies() async throws {
        let huge = String(repeating: "a", count: FullPageFetcher.maximumBytes + 1)
        let transport = StubTransport(html(huge))

        await #expect(throws: FullPageFetcher.Failure.tooLarge(bytes: FullPageFetcher.maximumBytes + 1)) {
            try await FullPageFetcher(transport: transport).fetch(url)
        }
    }
}
