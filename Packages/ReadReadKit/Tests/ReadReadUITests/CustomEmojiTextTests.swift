import Foundation
import Testing

@testable import ReadReadUI

/// Mastodon does not escape colons, so ordinary prose is full of them. Everything here is a case
/// where replacing the wrong thing would corrupt someone's post.
@Suite("CustomEmojiText")
struct CustomEmojiTextTests {

    private let known: Set<String> = ["blobcat", "party_parrot", "rust"]

    private func segments(_ text: String, known: Set<String>? = nil) -> [EmojiSegment] {
        CustomEmojiText.segments(of: AttributedString(text), shortcodes: known ?? self.known)
    }

    private func plain(_ segments: [EmojiSegment]) -> [String] {
        segments.map { segment in
            switch segment {
            case .text(let value): String(value.characters)
            case .emoji(let shortcode): "<\(shortcode)>"
            }
        }
    }

    @Test("A known shortcode is replaced")
    func replacesKnownShortcode() {
        #expect(plain(segments("hello :blobcat: there")) == ["hello ", "<blobcat>", " there"])
    }

    @Test("An unknown shortcode is left as text")
    func leavesUnknownShortcode() {
        // The instance did not send this emoji, so there is no image to show and the literal text
        // is the only honest rendering.
        #expect(plain(segments("look :nope: here")) == ["look :nope: here"])
    }

    @Test("A time of day is not an emoji")
    func doesNotEatTimes() {
        #expect(plain(segments("the train at 12:30 and again at 4:00")) ==
            ["the train at 12:30 and again at 4:00"])
    }

    @Test("A URL's colon is left alone")
    func doesNotEatURLs() {
        #expect(plain(segments("see https://example.com/a")) == ["see https://example.com/a"])
    }

    @Test("Consecutive emoji each become their own segment")
    func consecutiveEmoji() {
        #expect(plain(segments(":blobcat::rust:")) == ["<blobcat>", "<rust>"])
    }

    @Test("A doubled colon still finds the shortcode after it")
    func doubledColon() {
        // Skipping the whole run on a failed match would swallow the opening colon of the real
        // shortcode and leave the post reading `::blobcat::`.
        #expect(plain(segments("::blobcat::")) == [":", "<blobcat>", ":"])
    }

    @Test("Text with no emoji comes back as one segment")
    func plainTextIsOneSegment() {
        #expect(plain(segments("nothing to see")) == ["nothing to see"])
    }

    @Test("An instance that sent no emoji short-circuits")
    func noKnownShortcodes() {
        #expect(plain(segments(":blobcat:", known: [])) == [":blobcat:"])
    }

    @Test("An unterminated colon does not run away")
    func unterminatedShortcode() {
        #expect(plain(segments("ending on :blobcat")) == ["ending on :blobcat"])
    }

    @Test("An emoji at each end is handled without an empty segment")
    func emojiAtTheEdges() {
        #expect(plain(segments(":rust: middle :blobcat:")) ==
            ["<rust>", " middle ", "<blobcat>"])
    }

    @Test("Link attributes on the surrounding text survive")
    func preservesAttributes() throws {
        var attributed = AttributedString("see ")
        var link = AttributedString("example")
        link.link = URL(string: "https://example.com")
        attributed += link
        attributed += AttributedString(" :blobcat:")

        let result = CustomEmojiText.segments(of: attributed, shortcodes: known)

        // The whole reason this works on `AttributedString`: rebuilding from plain text would
        // strip every link in the post.
        guard case .text(let head) = result.first else {
            Issue.record("expected leading text, got \(result)")
            return
        }
        #expect(head.runs.contains { $0.link == URL(string: "https://example.com") })
    }
}
