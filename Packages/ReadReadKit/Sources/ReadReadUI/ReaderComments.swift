import Foundation
import ReadReadModel
import ReadReadSupport

/// Builds the markup for the discussion beneath an article.
///
/// Markup rather than SwiftUI views, unlike the Mastodon thread this is modelled on, and the
/// reason is where it has to appear. An article renders inside a web view that owns its own
/// scrolling, so native cards underneath it would be a second scroll view stacked on a first —
/// two scrollers, two sets of gestures, and a discussion you cannot reach by scrolling the thing
/// it belongs to. Put in the document instead, the comments scroll with the article, share its
/// measure, its typography and its reading-size setting, and inherit text selection and Find.
///
/// What it keeps from the thread is the *shape*: avatar, name, time, body, and a reply nested under
/// what it replies to.
enum ReaderComments {

    /// The id of the section this fills, and the reason the id is spelled this way.
    ///
    /// `comments` is what WordPress calls the container it wraps a discussion in, so the anchor a
    /// site's own "N comments" link points at resolves inside the reader document too — a link to
    /// `#comments` in an article scrolls to the comments instead of leaving for the browser.
    static let sectionID = "comments"

    /// How deep replies are drawn before later ones join their parent's level.
    ///
    /// A thread nests without limit and a reading pane does not: on a phone, five levels of indent
    /// leave a column two words wide. WordPress's own default caps threading at five for the same
    /// reason, so this is not a limitation being introduced so much as the one already there.
    static let maximumDepth = 4

    /// The section's inner markup for whatever the loader currently has.
    ///
    /// Three answers, not two, and the difference matters to the caller:
    ///
    /// - `nil` — leave the section exactly as it is. The feed does not load comments, so the
    ///   document has no section to write into in the first place.
    /// - `""` — empty the section and let it collapse. The fetch has not started yet, and a rule
    ///   with a heading over nothing reads as a discussion that failed to load rather than as one
    ///   that has not been asked for.
    /// - Anything else — the section's contents.
    static func markup(for state: CommentsLoader.State) -> String? {
        switch state {
        case .notRequested:
            nil
        case .pending:
            ""
        case .loading:
            note(String(localized: "Loading comments…"))
        case .failed(let message):
            note(message)
        case .loaded(.unsupported):
            // Said plainly rather than left blank: the reader turned this on for this feed, and
            // silence would read as the app having failed rather than as the site not offering it.
            note(String(localized: "This site does not publish its comments."))
        case .loaded(.threads(let nodes)):
            nodes.isEmpty ? note(String(localized: "No comments.")) : threads(nodes)
        case .loaded(.markup(let html)):
            // The page's own comment markup, already reduced and sanitised by
            // `WordPressComments.markup(in:baseURL:)`. Wrapped rather than restyled: the structure
            // is whatever the theme chose, so the most this can do is give it the reading pane's
            // typography and get out of the way.
            heading(nil) + "<div class=\"rr-comments-page\">\(html)</div>"
        }
    }

    // MARK: - Building

    private static func threads(_ nodes: [WordPressCommentNode]) -> String {
        heading(count(of: nodes)) + list(nodes, depth: 0)
    }

    private static func list(_ nodes: [WordPressCommentNode], depth: Int) -> String {
        guard !nodes.isEmpty else { return "" }
        return "<ol class=\"rr-thread\">\(items(nodes, depth: depth))</ol>"
    }

    /// The `<li>`s at one level of the thread.
    ///
    /// Separate from ``list(_:depth:)`` precisely so the cap below can add items to *this* level
    /// instead of opening another. Nesting them in a fresh list was the obvious way to write it and
    /// the wrong one: a list inside a list is indented by the stylesheet whatever depth it thinks
    /// it is at, so the flattened replies stepped right anyway and the cap bought nothing.
    private static func items(_ nodes: [WordPressCommentNode], depth: Int) -> String {
        nodes.map { node in
            guard depth + 1 < maximumDepth else {
                // At the limit, a reply's own replies become its siblings here: still after it,
                // still under the right ancestor, but no further right.
                return element(node.comment, replies: "")
                    + items(flattened(node.replies), depth: depth)
            }
            return element(node.comment, replies: list(node.replies, depth: depth + 1))
        }
        .joined()
    }

    private static func element(_ comment: WordPressComment, replies: String) -> String {
        "<li class=\"rr-comment\">\(head(of: comment))\(body(of: comment))\(replies)</li>"
    }

    /// Every descendant of these replies, in reading order, as one flat level.
    private static func flattened(_ nodes: [WordPressCommentNode]) -> [WordPressCommentNode] {
        nodes.flatMap { node in
            [WordPressCommentNode(comment: node.comment)] + flattened(node.replies)
        }
    }

    private static func head(of comment: WordPressComment) -> String {
        let avatar = comment.avatarURLString
            .flatMap { URL(string: $0) }
            // `https` only, and it is not a formality: this is a URL from a third party's API
            // being written into an `<img src>`, so the scheme check belongs here rather than
            // being assumed of whoever supplied it.
            .flatMap { $0.scheme == "https" ? $0 : nil }
            // `alt=""` on purpose. The avatar carries no information the name beside it does not,
            // so a screen reader announcing it would read every commenter's name twice.
            .map { "<img class=\"rr-avatar\" src=\"\(escaped($0.absoluteString))\" alt=\"\" loading=\"lazy\">" }
            ?? "<span class=\"rr-avatar rr-avatar-empty\" aria-hidden=\"true\"></span>"

        // The name is text, never a link, even when the commenter supplied an address. A comment
        // form is the one field on a web page that anybody at all can write a URL into, and a
        // reader that renders those as links is a link farm with a reading pane attached.
        let when = comment.publishedAt.formatted(date: .abbreviated, time: .shortened)

        return """
        <div class="rr-comment-head">\
        \(avatar)\
        <span class="rr-author">\(escaped(comment.authorName))</span>\
        <time class="rr-when" datetime="\(escaped(iso(comment.publishedAt)))">\(escaped(when))</time>\
        </div>
        """
    }

    private static func body(of comment: WordPressComment) -> String {
        "<div class=\"rr-comment-body\">\(comment.contentHTML)</div>"
    }

    private static func heading(_ count: Int?) -> String {
        let title = count.map { String(localized: "^[\($0) Comment](inflect: true)") }
            ?? String(localized: "Comments")
        return "<h2 class=\"rr-comments-title\">\(escaped(title))</h2>"
    }

    private static func note(_ text: String) -> String {
        "<p class=\"rr-comments-note\">\(escaped(text))</p>"
    }

    /// Comments at every level, which is what the heading counts.
    private static func count(of nodes: [WordPressCommentNode]) -> Int {
        nodes.reduce(0) { total, node in total + 1 + count(of: node.replies) }
    }

    private static func iso(_ date: Date) -> String {
        date.formatted(.iso8601)
    }

    /// Escapes text written into the markup around a comment.
    ///
    /// Its own copy rather than `ReaderDocument`'s, which is private to the document builder. The
    /// comment *body* is deliberately not escaped — it is HTML, already sanitised, and rendering it
    /// is the point — which is exactly why the name, the date and the heading must be.
    private static func escaped(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
