import Foundation
import ReadReadModel
import ReadReadSupport
import Testing

@testable import ReadReadUI

/// The comment section is markup this app writes by hand around markup a stranger wrote, so the
/// two things worth asserting are the shape a reader sees and the boundary between those two
/// halves: the body is HTML and is rendered, everything around it is text and must be escaped.
@Suite("ReaderComments")
@MainActor
struct ReaderCommentsTests {

    private func comment(
        _ id: Int,
        parent: Int = 0,
        author: String = "Jo",
        avatar: String? = "https://secure.gravatar.com/avatar/x?s=96",
        body: String = "<p>A thought.</p>",
        at offset: TimeInterval = 0
    ) -> WordPressComment {
        WordPressComment(
            id: id,
            parentID: parent,
            authorName: author,
            avatarURLString: avatar,
            publishedAt: Date(timeIntervalSince1970: 1_800_000_000 + offset),
            contentHTML: body
        )
    }

    private func markup(_ comments: [WordPressComment]) throws -> String {
        let state = CommentsLoader.State.loaded(.threads(WordPressComment.trees(from: comments)))
        return try #require(ReaderComments.markup(for: state))
    }

    // MARK: - Shape

    @Test("A comment is drawn as an avatar, a name, a time and its body")
    func drawsAComment() throws {
        let html = try markup([comment(1)])

        #expect(html.contains("class=\"rr-avatar\""))
        #expect(html.contains("secure.gravatar.com"))
        #expect(html.contains(">Jo<"))
        #expect(html.contains("<time class=\"rr-when\""))
        #expect(html.contains("<p>A thought.</p>"))
    }

    @Test("Replies nest inside the comment they reply to")
    func nestsReplies() throws {
        let html = try markup([
            comment(1, at: 0),
            comment(2, parent: 1, at: 10),
        ])

        // The reply's list opens inside the parent's item, which is what the indent is drawn from.
        let parent = try #require(html.range(of: "<li class=\"rr-comment\">"))
        let nested = try #require(html.range(of: "<ol class=\"rr-thread\">", range: parent.upperBound..<html.endIndex))
        #expect(nested.lowerBound > parent.lowerBound)
        #expect(html.contains("</li></ol></li>"))
    }

    /// A thread nests without limit and a reading pane does not: five levels of indent leave a
    /// column two words wide on a phone. Past the limit a reply joins its parent's level, which
    /// keeps it in the right order under the right ancestor without stepping further right.
    @Test("Nesting stops at the indent limit and flattens below it")
    func capsNesting() throws {
        let chain = (1...8).map { index in
            comment(index, parent: index == 1 ? 0 : index - 1, at: TimeInterval(index) * 10)
        }
        let html = try markup(chain)

        // One list for the roots plus one per level of indent, and no more.
        let lists = html.components(separatedBy: "<ol class=\"rr-thread\">").count - 1
        #expect(lists == ReaderComments.maximumDepth)
        // Nothing is lost to the cap.
        for index in 1...8 {
            #expect(html.contains("<p>A thought.</p>"))
            #expect(html.contains(">Jo<"), "comment \(index) missing")
        }
        #expect(html.components(separatedBy: "<li class=\"rr-comment\">").count - 1 == 8)
    }

    @Test("The heading counts every comment, replies included")
    func countsAllComments() throws {
        let html = try markup([
            comment(1, at: 0),
            comment(2, parent: 1, at: 10),
            comment(3, parent: 2, at: 20),
        ])
        #expect(html.contains("3"))
        #expect(html.contains("rr-comments-title"))
    }

    // MARK: - The escaping boundary

    /// The name, the date and the heading are *text*. The body is HTML and is deliberately not
    /// escaped, which is exactly why everything around it must be.
    @Test("A commenter's name cannot break out of the markup around it")
    func escapesAuthorNames() throws {
        let html = try markup([comment(1, author: "<script>steal()</script>")])

        #expect(!html.contains("<script>"))
        #expect(html.contains("&lt;script&gt;"))
    }

    /// A commenter-supplied address is the one URL on a web page that anybody at all can write.
    /// Rendering those as links makes a reader into a link farm.
    @Test("A commenter's address is never rendered as a link")
    func doesNotLinkAuthors() throws {
        let comment = WordPressComment(
            id: 1,
            authorName: "Spam",
            authorURLString: "https://pills.example",
            publishedAt: Date(timeIntervalSince1970: 1_800_000_000),
            contentHTML: "<p>Hi</p>"
        )
        let html = try markup([comment])

        #expect(html.contains(">Spam<"))
        #expect(!html.contains("pills.example"))
    }

    /// An avatar URL is written straight into an `<img src>`, so the scheme check belongs at that
    /// point rather than being assumed of whoever supplied it.
    @Test("An avatar that is not https is dropped rather than rendered")
    func refusesUnsafeAvatars() throws {
        let html = try markup([comment(1, avatar: "javascript:steal()")])

        #expect(!html.contains("javascript:"))
        // The row still lines up, because the space the avatar would have taken is kept.
        #expect(html.contains("rr-avatar-empty"))
    }

    @Test("A comment with no avatar keeps the space one would have taken")
    func placeholdsMissingAvatars() throws {
        let html = try markup([comment(1, avatar: nil)])
        #expect(html.contains("rr-avatar-empty"))
        #expect(!html.contains("<img"))
    }

    // MARK: - States

    /// `nil` is what tells the caller to leave the section alone, as opposed to emptying it.
    @Test("A feed that does not load comments produces no markup at all")
    func silentWhenNotRequested() {
        #expect(ReaderComments.markup(for: .notRequested) == nil)
    }

    /// Empty, and emphatically not `nil`. While the comments are waiting for the article to finish
    /// there is a section in the document, and it has to collapse rather than draw a rule and a
    /// heading over nothing — which reads as a discussion that failed to load.
    @Test("A queued fetch empties the section rather than leaving it alone")
    func emptyWhilePending() {
        #expect(ReaderComments.markup(for: .pending) == "")
    }

    @Test("Every state that has something to say, says it")
    func speaksInEveryOtherState() throws {
        let states: [CommentsLoader.State] = [
            .loading,
            .failed("Something went wrong."),
            .loaded(.unsupported),
            .loaded(.threads([])),
        ]
        for state in states {
            let html = try #require(ReaderComments.markup(for: state), "silent in \(state)")
            #expect(html.contains("rr-comments-note"))
        }
    }

    @Test("A failure message reaches the reader")
    func showsFailureMessages() throws {
        let html = try #require(ReaderComments.markup(for: .failed("The site answered with an error (500).")))
        #expect(html.contains("500"))
    }

    /// The fallback path: the structure is whatever the theme produced, so all this does is give it
    /// the reading pane's typography and get out of the way.
    @Test("The page's own comment markup is wrapped, not rebuilt")
    func wrapsPageMarkup() throws {
        let html = try #require(
            ReaderComments.markup(for: .loaded(.markup("<ol><li><p>From the theme.</p></li></ol>")))
        )
        #expect(html.contains("rr-comments-page"))
        #expect(html.contains("<p>From the theme.</p>"))
        // No count, because a count of theme markup would be a guess.
        #expect(html.contains("rr-comments-title"))
    }
}
