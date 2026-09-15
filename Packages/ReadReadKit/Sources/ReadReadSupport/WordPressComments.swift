import Foundation

/// One comment on a WordPress post.
///
/// Deliberately not a mirror of the REST resource — it keeps the seven fields a reader needs and
/// drops the twenty it does not (`author_ip`, `status`, `type`, `meta`, `_links`…). The narrow
/// shape is what lets the same value serve both the REST path and, one day, any other source of
/// the same idea.
public struct WordPressComment: Sendable, Equatable, Identifiable {

    public var id: Int

    /// The comment this one replies to, or `0` for a top-level comment.
    ///
    /// WordPress's own sentinel, kept as-is rather than mapped to `Int?`: the API sends `0`, the
    /// tree builder compares against `0`, and a translation in between is one more place for the
    /// two to disagree about what a root is.
    public var parentID: Int

    public var authorName: String

    /// The address the commenter gave, if any. Empty strings from the API arrive here as `nil`.
    public var authorURLString: String?

    public var avatarURLString: String?

    public var publishedAt: Date

    /// The comment body as WordPress rendered it, **already sanitised**.
    ///
    /// Sanitised at the point it is decoded rather than at the point it is displayed, so there is
    /// no window in which an un-sanitised value exists in a variable someone could pass onwards.
    /// A comment is text a stranger typed into someone else's website; it is the least trustworthy
    /// markup this app renders.
    public var contentHTML: String

    public init(
        id: Int,
        parentID: Int = 0,
        authorName: String,
        authorURLString: String? = nil,
        avatarURLString: String? = nil,
        publishedAt: Date,
        contentHTML: String
    ) {
        self.id = id
        self.parentID = parentID
        self.authorName = authorName
        self.authorURLString = authorURLString
        self.avatarURLString = avatarURLString
        self.publishedAt = publishedAt
        self.contentHTML = contentHTML
    }
}

/// A comment and the replies beneath it.
///
/// Mirrors how WordPress itself nests a discussion, and how a Mastodon thread reads: the reply
/// sits under what it replies to rather than in a flat list ordered by time.
public struct WordPressCommentNode: Sendable, Equatable, Identifiable {

    public var comment: WordPressComment
    public var replies: [WordPressCommentNode]

    public var id: Int { comment.id }

    public init(comment: WordPressComment, replies: [WordPressCommentNode] = []) {
        self.comment = comment
        self.replies = replies
    }
}

public extension WordPressComment {

    /// Arranges a flat list of comments into reply trees, oldest first at every level.
    ///
    /// Three things it has to survive, all of which occur in real comment sections:
    ///
    /// - **A missing parent.** WordPress's REST collection is paged, a moderator can delete a
    ///   comment that has replies, and `?post=` excludes comments on other posts. Any comment
    ///   whose parent is not in this list is promoted to the top level rather than dropped — a
    ///   reply with nowhere to hang is still something the commenter wrote.
    /// - **A cycle.** `parent` is an id from a database, not a proof of acyclicity. The walk marks
    ///   as it descends, so a comment can appear at most once and a cycle cannot recurse forever.
    ///   Terminating is not enough on its own, though: every member of a cycle has a parent that
    ///   exists, so none of them is a child of the root and descending from the root alone would
    ///   return *nothing* for them. Whatever the walk could not reach is promoted afterwards.
    /// - **Order.** The API is asked for ascending date, but paging and a mid-refresh insertion can
    ///   still deliver them out of order, so each level is sorted here rather than trusted.
    static func trees(from comments: [WordPressComment]) -> [WordPressCommentNode] {
        let byID = Dictionary(comments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var childrenByParent: [Int: [WordPressComment]] = [:]
        for comment in comments {
            // A parent outside this list is no parent at all. Checked against `byID` rather than
            // against `parentID != 0`, which is what promotes an orphaned reply.
            let parent = byID[comment.parentID] == nil ? 0 : comment.parentID
            childrenByParent[parent, default: []].append(comment)
        }

        var visited: Set<Int> = []

        func build(childrenOf parentID: Int) -> [WordPressCommentNode] {
            let children = (childrenByParent[parentID] ?? [])
                .sorted { ($0.publishedAt, $0.id) < ($1.publishedAt, $1.id) }

            return children.compactMap { comment in
                // A comment already placed cannot be placed again, which is what bounds a cycle.
                guard visited.insert(comment.id).inserted else { return nil }
                return WordPressCommentNode(comment: comment, replies: build(childrenOf: comment.id))
            }
        }

        var roots = build(childrenOf: 0)

        // Anything the descent could not reach. A cycle is the case that produces these: each of
        // its members has a parent that exists, so the root has no path to any of them and they
        // would vanish entirely rather than merely be mis-nested.
        for comment in comments.sorted(by: { ($0.publishedAt, $0.id) < ($1.publishedAt, $1.id) })
        where !visited.contains(comment.id) {
            guard visited.insert(comment.id).inserted else { continue }
            roots.append(WordPressCommentNode(comment: comment, replies: build(childrenOf: comment.id)))
        }

        // Sorted once at the end rather than relying on the descent's order, because the promoted
        // ones were appended after it.
        return roots.sorted { ($0.comment.publishedAt, $0.id) < ($1.comment.publishedAt, $1.id) }
    }
}

/// Finds a WordPress post's comments from its own page.
///
/// Two routes, in this order, and the order is the whole design:
///
/// 1. **The REST API.** WordPress advertises it in every page's `<head>`, and
///    `wp/v2/comments?post=<id>` returns the discussion as data — author, avatar, date, body and
///    the `parent` that makes it a thread rather than a list. Structure is the reason to prefer it:
///    a threaded rendering cannot be recovered from markup a theme chose.
/// 2. **The page's own `#comments`.** Where the REST API is switched off, filtered, or behind a
///    login, the comments are still in the page, in the container every WordPress theme since the
///    default ones has used. Flatter and coarser, but it is the difference between showing the
///    discussion and showing nothing.
public enum WordPressComments {

    /// Where a post's comments can be fetched as data.
    public struct Endpoint: Sendable, Equatable {

        /// The `wp/v2/comments` collection on the site the article came from.
        ///
        /// A whole URL rather than a site root plus a path, because WordPress exposes the same API
        /// at two shapes — `…/wp-json/wp/v2/comments` where permalinks are pretty and
        /// `…/?rest_route=/wp/v2/comments` where they are not — and resolving which is which is a
        /// job to do once, at discovery, not at every page of every fetch.
        public var collectionURL: URL

        public var postID: Int

        public init(collectionURL: URL, postID: Int) {
            self.collectionURL = collectionURL
            self.postID = postID
        }

        /// One page of this post's comments, oldest first.
        ///
        /// `_fields` is not an optimisation for its own sake: a comment resource carries `meta`,
        /// `_links` and a second rendered copy of the body, and a busy post's collection is
        /// several times larger unasked than asked.
        public func requestURL(page: Int, perPage: Int = maximumPerPage) -> URL? {
            guard var components = URLComponents(url: collectionURL, resolvingAgainstBaseURL: false)
            else { return nil }

            var items = components.queryItems ?? []
            items.append(contentsOf: [
                URLQueryItem(name: "post", value: String(postID)),
                URLQueryItem(name: "per_page", value: String(min(max(perPage, 1), Self.maximumPerPage))),
                URLQueryItem(name: "page", value: String(max(page, 1))),
                URLQueryItem(name: "order", value: "asc"),
                URLQueryItem(name: "orderby", value: "date_gmt"),
                URLQueryItem(
                    name: "_fields",
                    value: "id,parent,author_name,author_url,author_avatar_urls,date_gmt,content"
                ),
            ])
            components.queryItems = items
            return components.url
        }

        /// The most WordPress will return in one request; asking for more is a 400.
        public static let maximumPerPage = 100
    }

    // MARK: - REST discovery

    /// The comments endpoint a page advertises, if it is a WordPress page at all.
    ///
    /// Discovery is what makes "is this a WordPress feed?" answerable without asking the user or
    /// guessing from the feed URL. Both markers below are emitted by WordPress core, not by a
    /// theme, so they are present on a default install and survive a redesign.
    public static func endpoint(in html: String, baseURL: URL?) -> Endpoint? {
        let root = HTMLParser.parse(html)
        let links = root.descendants.filter { $0.name == "link" }

        // The post's own REST resource: `<link rel="alternate" type="application/json"
        // href="…/wp/v2/posts/123">`. The single best marker there is — it identifies WordPress,
        // the API's location and the post's id in one attribute, with no second request and no
        // slug matching.
        for link in links where link.attribute("type")?.lowercased() == "application/json" {
            guard let href = link.attribute("href"),
                  let resolved = URL(string: href, relativeTo: baseURL)?.absoluteURL,
                  let postID = postID(inPostsRoute: resolved),
                  let collection = rerouted(resolved, from: "posts", to: "comments")
            else { continue }
            return Endpoint(collectionURL: collection, postID: postID)
        }

        // Older installs, and pages where a plugin removed the JSON `<link>` but left the API
        // root. The root says where the API is; the id has to come from elsewhere in the page.
        guard let apiRoot = links.lazy.compactMap({ link -> URL? in
            guard link.attribute("rel")?.lowercased() == "https://api.w.org/",
                  let href = link.attribute("href")
            else { return nil }
            return URL(string: href, relativeTo: baseURL)?.absoluteURL
        }).first else { return nil }

        guard let postID = postID(in: root, baseURL: baseURL),
              let collection = route("wp/v2/comments", under: apiRoot)
        else { return nil }

        return Endpoint(collectionURL: collection, postID: postID)
    }

    /// The post id, from whichever marker the page happens to carry.
    ///
    /// Both are core output. `rel="shortlink"` is the `?p=<id>` permalink WordPress emits in the
    /// head; the `postid-<id>` body class is what `body_class()` puts there and what every theme
    /// inherits. Tried in that order because the shortlink is unambiguous whereas a class list is
    /// a string other things also write into.
    static func postID(in root: HTMLElement, baseURL: URL?) -> Int? {
        for link in root.descendants
        where link.name == "link" && link.attribute("rel")?.lowercased() == "shortlink" {
            guard let href = link.attribute("href"),
                  let resolved = URL(string: href, relativeTo: baseURL)?.absoluteURL,
                  let components = URLComponents(url: resolved, resolvingAgainstBaseURL: false),
                  let value = components.queryItems?.first(where: { $0.name == "p" })?.value,
                  let id = Int(value), id > 0
            else { continue }
            return id
        }

        for body in root.descendants where body.name == "body" {
            guard let classes = body.attribute("class") else { continue }
            for token in classes.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }) {
                // `page-id-` as well as `postid-`: a WordPress *page* has comments too, and its
                // body class is spelled differently for historical reasons.
                for prefix in ["postid-", "page-id-"] where token.hasPrefix(prefix) {
                    if let id = Int(token.dropFirst(prefix.count)), id > 0 { return id }
                }
            }
        }

        return nil
    }

    /// The `<id>` in a `wp/v2/posts/<id>` REST URL, in either of the API's two shapes.
    private static func postID(inPostsRoute url: URL) -> Int? {
        guard let route = restRoute(of: url) else { return nil }
        let parts = route.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 4, parts[parts.count - 2] == "posts", let id = Int(parts[parts.count - 1]), id > 0
        else { return nil }
        return id
    }

    /// The API path a REST URL addresses, whichever shape it is written in.
    ///
    /// `…/wp-json/wp/v2/posts/9` and `…/?rest_route=/wp/v2/posts/9` are the same request. Reducing
    /// both to `wp/v2/posts/9` here is what lets everything downstream stop caring which it was.
    private static func restRoute(of url: URL) -> String? {
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let route = components.queryItems?.first(where: { $0.name == "rest_route" })?.value {
            return route
        }
        guard let range = url.path.range(of: "/wp-json/") else { return nil }
        return String(url.path[range.upperBound...])
    }

    /// Rewrites the last-but-one path segment of a REST URL — `posts/9` becomes `comments`.
    ///
    /// Rewriting rather than rebuilding from a site root, so an install that serves its API from
    /// somewhere unusual keeps serving it from there.
    private static func rerouted(_ url: URL, from: String, to: String) -> URL? {
        guard let route = restRoute(of: url) else { return nil }
        var parts = route.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2, parts[parts.count - 2] == from else { return nil }
        parts.removeLast(2)
        parts.append(to)
        return rewrite(url, route: parts.joined(separator: "/"))
    }

    /// Places `path` under an advertised API root, in whichever shape that root uses.
    private static func route(_ path: String, under root: URL) -> URL? {
        if let components = URLComponents(url: root, resolvingAgainstBaseURL: false),
           (components.queryItems ?? []).contains(where: { $0.name == "rest_route" }) {
            return rewrite(root, route: path)
        }
        return URL(string: path, relativeTo: root)?.absoluteURL
    }

    /// Writes `route` into a URL, keeping the shape — query parameter or path — it already had.
    private static func rewrite(_ url: URL, route: String) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }

        if var items = components.queryItems,
           let index = items.firstIndex(where: { $0.name == "rest_route" }) {
            // Leading slash restored: `rest_route` is a path and WordPress matches it as one.
            items[index].value = "/" + route
            components.queryItems = items
            return components.url
        }

        guard let range = components.path.range(of: "/wp-json/") else { return nil }
        components.path = String(components.path[..<range.upperBound]) + route
        components.queryItems = nil
        return components.url
    }

    // MARK: - Markup fallback

    /// The discussion as the page itself rendered it, taken from `#comments`.
    ///
    /// `#comments` because that is the container WordPress's own `comments_template()` has wrapped
    /// the discussion in since the default themes established it, so it is the one selector that
    /// holds across themes without knowing anything about them.
    ///
    /// What comes back is *reduced*, not merely sanitised. A theme's `#comments` also holds the
    /// reply form, the "Leave a Reply" heading, per-comment Reply and Edit links and the older /
    /// newer pagination — all of it interactive furniture belonging to a page nobody is looking at,
    /// and none of it removable by the sanitiser, which strips attributes rather than meaning. So
    /// those subtrees are dropped by name and by class before serialising, leaving the comments.
    public static func markup(in html: String, baseURL: URL?) -> String? {
        let root = HTMLParser.parse(html)
        guard let container = root.descendants.first(where: { $0.attribute("id") == "comments" })
        else { return nil }

        // The list inside the container where there is one: it holds the comments and nothing
        // else, which spares the reduction below from having to be exhaustive.
        let subject = container.descendants.first { element in
            (element.name == "ol" || element.name == "ul")
                && Self.listClasses.contains(where: element.classAndID.contains)
        } ?? container

        reduce(subject)

        let reduced = HTMLSanitizer.sanitize(subject, baseURL: baseURL)
        // An empty container is what a page with no comments looks like, and is not worth a
        // section of its own.
        return subject.text.isEmpty ? nil : reduced
    }

    /// Classes WordPress and its themes give the comment list itself.
    private static let listClasses = ["comment-list", "commentlist", "comments-list"]

    /// Elements that are never part of a comment's text.
    ///
    /// Dropped with their contents, which is the part the sanitiser cannot do: an unknown element
    /// there is *unwrapped* so that text inside a custom tag survives, and unwrapping a `<form>`
    /// leaves its labels and button captions behind as prose.
    private static let furnitureTags: Set<String> = [
        "form", "input", "textarea", "button", "select", "option", "label", "fieldset", "legend",
        "script", "style", "noscript", "iframe", "template",
    ]

    /// Class and id fragments marking the furniture around a discussion.
    private static let furnitureClasses = [
        "respond", "reply-title", "comment-form", "comment-reply-link", "comment-navigation",
        "comments-navigation", "comment-nav", "nav-links", "edit-link", "comment-edit-link",
        "comment-subscription", "akismet", "sharedaddy",
    ]

    /// Strips the furniture from a comments container in place.
    private static func reduce(_ container: HTMLElement) {
        // Collected before anything is removed: `descendants` walks the tree that removal is
        // rearranging, and mutating during that walk drops siblings of whatever was removed.
        let doomed = container.descendants.filter { element in
            furnitureTags.contains(element.name)
                || furnitureClasses.contains(where: element.classAndID.contains)
        }
        for element in doomed {
            element.removeFromParent()
        }
    }
}
