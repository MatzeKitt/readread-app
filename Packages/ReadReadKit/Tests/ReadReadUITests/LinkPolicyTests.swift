import Foundation
import Testing

@testable import ReadReadUI

/// Which links go to the in-app browser. The interesting cases are the ones that must *not*:
/// `SFSafariViewController` accepts http and https and only those, and raises on anything else
/// rather than declining — so a `mailto:` sent to it is a crash, not a wrong destination.
@Suite("Link destinations")
struct LinkPolicyTests {

    private func url(_ string: String) throws -> URL {
        try #require(URL(string: string))
    }

    @Test("A web page opens in the app when that is the setting")
    func webPagesOpenInApp() throws {
        let destination = LinkPolicy.destination(for: try url("https://example.com/piece"), opensInApp: true)

        #if os(iOS)
        #expect(destination == .inAppBrowser)
        #else
        // No in-app browser on the Mac, whatever the stored setting says.
        #expect(destination == .system)
        #endif
    }

    @Test("Plain http counts as a web page")
    func plainHTTPOpensInApp() throws {
        let destination = LinkPolicy.destination(for: try url("http://example.com"), opensInApp: true)

        #if os(iOS)
        #expect(destination == .inAppBrowser)
        #else
        #expect(destination == .system)
        #endif
    }

    @Test("Turning the setting off sends everything to the browser")
    func theSettingIsHonoured() throws {
        #expect(
            LinkPolicy.destination(for: try url("https://example.com"), opensInApp: false) == .system
        )
    }

    /// Each of these is a request to leave for another app, not to read a page.
    @Test(
        "Anything that is not a web page goes to the system",
        arguments: [
            "mailto:someone@example.com",
            "tel:+49123456789",
            "sms:+49123456789",
            "itms-apps://apps.apple.com/app/id1234567890",
            "readread://oauth-callback",
            "file:///etc/hosts",
            "javascript:alert(1)",
        ]
    )
    func nonWebSchemesGoToTheSystem(_ string: String) throws {
        #expect(LinkPolicy.destination(for: try url(string), opensInApp: true) == .system)
    }

    /// A scheme is case-insensitive per RFC 3986, and a feed's markup is not always tidy.
    @Test("An upper-case scheme is still a web page")
    func schemeComparisonIsCaseInsensitive() throws {
        let destination = LinkPolicy.destination(for: try url("HTTPS://example.com"), opensInApp: true)

        #if os(iOS)
        #expect(destination == .inAppBrowser)
        #else
        #expect(destination == .system)
        #endif
    }
}

/// Links tapped inside a rendered article do not go through `openURL` at all — the web view
/// navigates itself, replacing the article in the pane with no way back. These cover the decision
/// about which of those navigations to intercept.
@MainActor
@Suite("Article link routing")
struct ArticleLinkRoutingTests {

    private func url(_ string: String) throws -> URL {
        try #require(URL(string: string))
    }

    @Test("A link to another site leaves the pane")
    func externalLinksAreHandedOff() throws {
        #expect(ArticleLinkRouter.shouldHandOff(
            try url("https://elsewhere.example/page"),
            baseURL: try url("https://example.com/piece")
        ))
    }

    /// A footnote marker is a scroll, and opening a browser on the page you are already reading
    /// would be absurd.
    @Test("An anchor inside the article is left to scroll")
    func fragmentsIntoTheArticleStay() throws {
        #expect(!ArticleLinkRouter.shouldHandOff(
            try url("https://example.com/piece#footnote-3"),
            baseURL: try url("https://example.com/piece")
        ))
    }

    /// Same page, but a different one — a fragment on another URL is a destination.
    @Test("An anchor on a different page still leaves")
    func fragmentsElsewhereAreHandedOff() throws {
        #expect(ArticleLinkRouter.shouldHandOff(
            try url("https://example.com/other#section"),
            baseURL: try url("https://example.com/piece")
        ))
    }

    /// A feed item with no URL of its own renders against `about:blank`, so there is no article
    /// page for an anchor to be inside of.
    @Test("With no article URL, every link leaves")
    func noBaseURLMeansHandOff() throws {
        #expect(ArticleLinkRouter.shouldHandOff(try url("https://example.com/piece#x"), baseURL: nil))
        #expect(ArticleLinkRouter.shouldHandOff(try url("https://example.com/piece"), baseURL: nil))
    }

    /// The query is part of which page this is, so an anchor on a differently-parameterised URL
    /// is a different page.
    @Test("A differing query is a different page")
    func queryIsPartOfIdentity() throws {
        #expect(ArticleLinkRouter.shouldHandOff(
            try url("https://example.com/piece?page=2#top"),
            baseURL: try url("https://example.com/piece")
        ))
    }

    /// Mail and telephone links in an article body have to reach the system, which means they must
    /// be handed off rather than allowed — a `WKWebView` does nothing at all with them.
    @Test("A mail link is handed off rather than left to the web view")
    func mailLinksAreHandedOff() throws {
        #expect(ArticleLinkRouter.shouldHandOff(
            try url("mailto:editor@example.com"),
            baseURL: try url("https://example.com/piece")
        ))
    }
}
