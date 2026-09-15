import Foundation
import Testing

@testable import ReadReadUI

/// A federated timeline carries posts from instances whose own limit is far above Mastodon's 500
/// characters, and one of those turns a timeline row into several screens with the next post below
/// the horizon.
@MainActor
@Suite("Post length in the list")
struct StatusTextClippingTests {

    private func words(_ count: Int) -> String {
        (0..<count).map { "word\($0)" }.joined(separator: " ")
    }

    @Test("A short post is left exactly as it is")
    func shortPostsAreUntouched() {
        let text = AttributedString("A perfectly ordinary post.")
        let clipped = StatusTextCache.clipped(text)

        #expect(String(clipped.characters) == "A perfectly ordinary post.")
        // No ellipsis on something that was not cut.
        #expect(!String(clipped.characters).hasSuffix("…"))
    }

    @Test("A post exactly at the limit is not cut")
    func theLimitItselfIsInclusive() {
        let text = AttributedString(String(repeating: "a", count: StatusTextCache.characterLimit))
        let clipped = StatusTextCache.clipped(text)

        #expect(clipped.characters.count == StatusTextCache.characterLimit)
        #expect(!String(clipped.characters).hasSuffix("…"))
    }

    @Test("A long post is cut to the limit and marked")
    func longPostsAreClipped() {
        let clipped = StatusTextCache.clipped(AttributedString(words(600)))
        let string = String(clipped.characters)

        #expect(string.hasSuffix("…"))
        // The ellipsis is allowed past the limit; the post's own text is not.
        #expect(clipped.characters.count <= StatusTextCache.characterLimit + 1)
        #expect(clipped.characters.count > StatusTextCache.characterLimit - 30)
    }

    @Test("The cut lands between words, not inside one")
    func cutsAtAWordBoundary() {
        let clipped = StatusTextCache.clipped(AttributedString(words(600)))
        let string = String(clipped.characters).dropLast()

        // Every word is "word<n>", so a mid-word cut leaves a truncated number — or worse, "wor".
        let last = try! #require(string.split(separator: " ").last)
        #expect(last.hasPrefix("word"))
        #expect(Int(last.dropFirst(4)) != nil)
        // And no gap left where the space was.
        #expect(!string.hasSuffix(" "))
    }

    /// A post can legitimately have no spaces near the cut — one long URL, or a language that does
    /// not write them. Searching back for a boundary must not then discard most of the post.
    @Test("A post with no spaces to find is cut where it is")
    func hardCutsWhenThereIsNoBoundary() {
        let solid = String(repeating: "x", count: 900)
        let clipped = StatusTextCache.clipped(AttributedString(solid))

        #expect(clipped.characters.count == StatusTextCache.characterLimit + 1)
        #expect(String(clipped.characters).hasSuffix("…"))
    }

    /// Clipping walks runs, so it has to put them back. Exercised through ``clipped(_:to:)``
    /// directly rather than through a row, because a row's own text now arrives here with its
    /// links already stripped — testing it there would assert nothing.
    @Test("Attributes before the cut survive it")
    func formattingSurvivesTheCut() {
        var text = Self.linked("Start the link", to: "https://example.com")
        text += AttributedString(" " + words(600))
        let clipped = StatusTextCache.clipped(text)

        #expect(clipped.runs.contains { $0.link?.absoluteString == "https://example.com" })
        #expect(String(clipped.characters).hasSuffix("…"))
        #expect(clipped.characters.count <= StatusTextCache.characterLimit + 1)
    }

    /// One attributed run, so the ellipsis has something to inherit if the cut is careless.
    private static func linked(_ text: String, to url: String) -> AttributedString {
        var attributed = AttributedString(text)
        attributed.link = URL(string: url)
        return attributed
    }

    /// The ellipsis must not inherit the attributes of the run it was appended to — the case that
    /// matters is a link ending exactly at the cut, which would grow a tappable "…" that goes
    /// somewhere.
    @Test("The ellipsis is not part of anything")
    func theEllipsisIsPlain() {
        let clipped = StatusTextCache.clipped(Self.linked(words(600), to: "https://example.com"))

        #expect(clipped.runs.last?.link == nil)
        #expect(String(clipped.characters).hasSuffix("…"))
    }

    /// The unparseable-markup path renders the stored plain text, and that is no shorter.
    @Test("The plain-text fallback is capped too")
    func fallbackIsClipped() {
        let text = StatusTextCache.shared.text(id: "plain-\(UUID())", html: nil, plain: words(600))

        #expect(String(text.characters).hasSuffix("…"))
        #expect(text.characters.count <= StatusTextCache.characterLimit + 1)
    }

    @Test("Mastodon's own limit is what is used")
    func theLimitIsFiveHundred() {
        #expect(StatusTextCache.characterLimit == 500)
    }
}
