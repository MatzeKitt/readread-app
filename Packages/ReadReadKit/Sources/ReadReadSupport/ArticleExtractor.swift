import Foundation

/// The readable body pulled out of a full web page.
public struct ExtractedArticle: Sendable, Equatable {

    /// Sanitised HTML for the article body only.
    public var html: String

    /// The page's own title, when it advertised one worth using.
    public var title: String?

    /// Length of the extracted plain text. Callers compare it against the feed's own content to
    /// decide whether the fetch improved on what they already had.
    public var textLength: Int

    public init(html: String, title: String?, textLength: Int) {
        self.html = html
        self.title = title
        self.textLength = textLength
    }
}

/// Pulls the article out of a full web page, on device.
///
/// A readability-style density heuristic: strip the furniture, score every block by how much prose
/// it holds relative to its link text, take the winner and its close siblings, and sanitise what
/// comes out.
///
/// ## Why this and not a headless web view
///
/// Rendering the page in a `WKWebView` and running a JavaScript readability port would extract
/// better from hostile pages — but it would also execute the page's own scripts, load its ads,
/// trackers and third-party frames, and let a site the user merely *scrolled past* run code. This
/// path issues exactly one request, for the HTML, and never runs any of it.
///
/// The cost is that a client-rendered page, which ships no article in its HTML at all, extracts
/// nothing. That is why ``extract(from:baseURL:)`` returns `nil` rather than a stub: the caller
/// keeps showing the feed's own content, which is the right outcome.
public enum ArticleExtractor {

    /// Shortest extraction worth showing. Below this the page is almost certainly client-rendered
    /// or paywalled, and the feed's own summary — however truncated — is the better answer.
    static let minimumTextLength = 200

    /// When the heuristic last changed in a way that changes what a page extracts to. Move it
    /// forward with every such change.
    ///
    /// Extractions are cached for good — the article, or the verdict that there was none — so
    /// without this a fix would only reach articles nobody had opened yet. The very pages it was
    /// written for would keep showing the feed's summary, or the article without its images.
    public static let lastRevised = Date(timeIntervalSince1970: 1_792_699_200) // 2026-10-22 20:00 UTC

    /// Extracts the readable body, or `nil` when the page has nothing usable in its HTML.
    public static func extract(from html: String, baseURL: URL?) -> ExtractedArticle? {
        let root = HTMLParser.parse(html)

        // Before stripping: `<title>` lives in `<head>`, and `<meta>` is discarded below.
        let title = documentTitle(in: root)

        // Before stripping too: `<noscript>` is discarded there, and with it the only real copy
        // of every lazily loaded image.
        restoreNoscriptImages(in: root)
        strip(root)

        let scorer = Scorer(root: root)
        guard let body = scorer.best() else { return nil }

        let kept = [body] + scorer.adjacentContent(of: body)
        let textLength = kept.reduce(0) { $0 + $1.text.count }
        guard textLength >= minimumTextLength else { return nil }

        let serialised = kept
            .map { HTMLSanitizer.sanitize($0, baseURL: baseURL) }
            .joined()
        guard !serialised.isEmpty else { return nil }

        return ExtractedArticle(html: serialised, title: title, textLength: textLength)
    }

    // MARK: - Lazy images

    /// Puts the image a `<noscript>` holds in place of the placeholder just before it.
    ///
    /// Lazy loaders ship a placeholder — a grey `data:` SVG, a spacer GIF — and leave the real file
    /// for a script to swap in, with a `<noscript>` copy for readers without one. Nothing here runs
    /// that script, and `<noscript>` is stripped, so without this only the placeholder survives,
    /// and the sanitiser then drops its `data:` source as well. heise does this to every image in
    /// an article: `<a-img src="…"><img src="data:…"></a-img><noscript><img src="…"></noscript>`.
    ///
    /// Only where a placeholder precedes it, as Readability does: a `<noscript>` image on its own
    /// is usually a tracking pixel or a copy of an image the page already shows.
    static func restoreNoscriptImages(in root: HTMLElement) {
        for noscript in root.descendants where noscript.name == "noscript" {
            guard let parent = noscript.parent,
                  case .text(let raw)? = noscript.children.first,
                  let image = singleImage(in: HTMLParser.parse(raw)),
                  let position = parent.children.firstIndex(where: { node in
                      if case .element(let element) = node { return element === noscript }
                      return false
                  })
            else { continue }

            let previous = parent.children[..<position].reversed().lazy.compactMap { node -> HTMLElement? in
                if case .element(let element) = node { element } else { nil }
            }.first
            guard let previous, singleImage(in: previous) != nil else { continue }

            previous.replace(with: image)
        }
    }

    /// The `<img>` an element amounts to: the element itself, or the only thing inside it however
    /// deeply wrapped, as long as no text sits beside it.
    private static func singleImage(in element: HTMLElement) -> HTMLElement? {
        if element.name == "img" { return element }
        let children = element.childElements
        guard children.count == 1, element.text.isEmpty else { return nil }
        return singleImage(in: children[0])
    }

    // MARK: - Stripping

    /// Elements dropped with their contents, before anything is scored.
    ///
    /// `nav`, `aside`, `header` and `footer` are the furniture the reader does not want. The rest
    /// are dropped for safety rather than tidiness: these are the elements that would execute,
    /// embed or transmit something.
    static let discardedTags: Set<String> = [
        "script", "style", "noscript", "template", "svg", "canvas", "iframe", "frame", "frameset",
        "object", "embed", "applet", "form", "input", "button", "select", "textarea", "label",
        "fieldset", "legend", "dialog", "menu", "link", "meta", "nav", "aside", "header", "footer",
    ]

    /// Class and id fragments that mark a block as furniture rather than article.
    ///
    /// Matched as plain substrings on purpose: `comment` has to catch `comments`,
    /// `comment-wrapper` and `js-commentList` alike, and a word-boundary match would miss all
    /// three.
    static let negativeSignals = [
        "comment", "share", "sharing", "social", "sidebar", "side-bar", "advert",
        "ad-container", "adsense", "banner", "promo", "sponsor", "related", "recirc",
        "newsletter", "subscribe", "signup", "sign-up", "paywall", "popup", "modal", "cookie",
        "consent", "breadcrumb", "pagination", "footer", "masthead", "menu", "navigation",
        "toolbar", "author-box", "disqus", "skip-link",
    ]

    /// Fragments that count against a block when scoring but are no reason to remove it.
    ///
    /// Page builders name their layout after widgets: heise wraps the whole article in
    /// `gridContainer DetailExtendedWidgets1`, Elementor puts every text block inside an
    /// `elementor-widget-container`. Stripping on `widget` threw the article away with the grid.
    static let weakNegativeSignals = ["widget"]

    /// Class and id fragments that mark a block as likely article.
    static let positiveSignals = [
        "article", "body", "content", "entry", "hentry", "main", "page", "post",
        "text", "blog", "story", "column", "prose",
    ]

    /// ARIA landmark roles that are, by definition, not the article.
    private static let discardedRoles: Set<String> = [
        "navigation", "banner", "complementary", "search", "contentinfo", "menu", "menubar",
    ]

    /// Removes everything that cannot be the article.
    static func strip(_ root: HTMLElement) {
        for element in root.descendants {
            // `descendants` is a snapshot taken before any removal, so an element inside an
            // already-removed subtree is still in the list — and no longer has a parent.
            guard element.parent != nil else { continue }

            if discardedTags.contains(element.name) {
                element.removeFromParent()
                continue
            }
            if element.attributes["hidden"] != nil || element.attributes["aria-hidden"] == "true" {
                element.removeFromParent()
                continue
            }
            if let role = element.attributes["role"], discardedRoles.contains(role) {
                element.removeFromParent()
                continue
            }

            // Furniture that names itself as such — but not where it also names itself as the
            // article: a wrapper classed `post-content comment-count` must not be thrown away
            // over its second token.
            let signature = element.classAndID
            if !signature.isEmpty,
               negativeSignals.contains(where: signature.contains),
               !positiveSignals.contains(where: signature.contains) {
                element.removeFromParent()
            }
        }
    }

    // MARK: - Scoring

    /// Scores an already-stripped tree and picks the article out of it.
    ///
    /// Scores live in a side table keyed by object identity rather than as fields on the tree, so
    /// ``HTMLElement`` stays a plain document type and nothing the scorer invents can leak into
    /// the serialised output.
    struct Scorer {

        /// Scored elements in the order they were first credited. Holds the only strong references
        /// the scorer needs, which is what keeps `scores` addressable.
        private var candidates: [HTMLElement] = []
        private var scores: [ObjectIdentifier: Double] = [:]

        /// The blocks whose presence marks their container as prose.
        ///
        /// Deliberately excludes `<li>`. A Wikipedia reference list out-scored the article body
        /// three ways at once when list items counted — hundreds of them, each comma-dense, all
        /// crediting the same `<ol>` — and the same shape appears in any "related links" rail.
        /// List items still reach the reader: they are inside whichever container the paragraphs
        /// win, they just do not get a vote on which container that is.
        private static let textBlocks: Set<String> = ["p", "pre", "td", "blockquote"]

        init(root: HTMLElement) {
            for element in root.descendants where Self.textBlocks.contains(element.name) {
                let text = element.text
                guard text.count >= 25 else { continue }

                // Readability's shape: a base worth one point, plus a point per comma, plus up to
                // three for sheer length. Credited to the parent and half to the grandparent,
                // because the article is the *container* of many such blocks, not any one of them.
                let base = 1 + Double(text.filter { $0 == "," || $0 == "，" }.count)
                    + min(Double(text.count) / 100, 3)

                if let parent = element.parent, parent.name != "#root" {
                    credit(base, to: parent)
                }
                if let grandparent = element.parent?.parent, grandparent.name != "#root" {
                    credit(base / 2, to: grandparent)
                }
            }
        }

        private mutating func credit(_ base: Double, to element: HTMLElement) {
            let key = ObjectIdentifier(element)

            if let existing = scores[key] {
                scores[key] = existing + base
                return
            }
            // The structural priors are seeded once, on the element's first contribution, so a
            // container of fifty paragraphs does not collect its `<article>` bonus fifty times.
            candidates.append(element)
            scores[key] = tagBonus(element) + signalBonus(element) + base
        }

        /// Link density is applied last, as a multiplier: a block of pure navigation can
        /// accumulate a high raw score from long link text, and this is what separates it from
        /// prose.
        func adjustedScore(of element: HTMLElement) -> Double {
            guard let raw = scores[ObjectIdentifier(element)] else { return 0 }
            return raw * (1 - linkDensity(of: element))
        }

        /// The block most likely to be the article.
        func best() -> HTMLElement? {
            candidates.max { adjustedScore(of: $0) < adjustedScore(of: $1) }
        }

        /// Every scored block, best first. Only used to reason about why a page extracted the way
        /// it did — the heuristic's near-misses are what a wrong answer has to be diagnosed from.
        func ranked() -> [(element: HTMLElement, score: Double)] {
            candidates
                .map { (element: $0, score: adjustedScore(of: $0)) }
                .sorted { $0.score > $1.score }
        }

        /// Siblings of the winner that are plainly part of the same article.
        ///
        /// Articles are routinely split across several sibling `<div>`s — a lede, the body, a pull
        /// quote — and taking only the single highest-scoring node truncates them. A sibling is
        /// kept when it scores respectably in its own right, or when it is a substantial paragraph
        /// that is mostly prose rather than links.
        func adjacentContent(of body: HTMLElement) -> [HTMLElement] {
            let bar = max(10, adjustedScore(of: body) * 0.2)

            return body.siblings.filter { sibling in
                if adjustedScore(of: sibling) >= bar { return true }
                guard sibling.name == "p" else { return false }
                let text = sibling.text
                return text.count > 80 && linkDensity(of: sibling) < 0.25
            }
        }

        /// A structural prior: `<article>` and `<main>` say what they are, and a `<li>` or a
        /// heading almost never *is* the article however much text it holds.
        private func tagBonus(_ element: HTMLElement) -> Double {
            switch element.name {
            case "article", "main": 25
            case "section": 8
            case "div": 5
            case "pre", "td", "blockquote": 3
            case "address", "ol", "ul", "dl", "dd", "dt", "li", "form": -3
            case "h1", "h2", "h3", "h4", "h5", "h6", "th": -5
            default: 0
            }
        }

        private func signalBonus(_ element: HTMLElement) -> Double {
            let signature = element.classAndID
            guard !signature.isEmpty else { return 0 }
            if positiveSignals.contains(where: signature.contains) { return 12 }
            if negativeSignals.contains(where: signature.contains)
                || weakNegativeSignals.contains(where: signature.contains) { return -12 }
            return 0
        }
    }

    /// Proportion of an element's text that sits inside links.
    static func linkDensity(of element: HTMLElement) -> Double {
        let total = element.text.count
        guard total > 0 else { return 0 }
        let linked = element.descendants
            .filter { $0.name == "a" }
            .reduce(0) { $0 + $1.text.count }
        return min(1, Double(linked) / Double(total))
    }

    // MARK: - Title

    static func documentTitle(in root: HTMLElement) -> String? {
        // `og:title` first: it is the headline the publisher chose, without the " | Site Name"
        // suffix that `<title>` almost always carries.
        for element in root.descendants where element.name == "meta" {
            let key = element.attributes["property"] ?? element.attributes["name"] ?? ""
            guard key == "og:title" || key == "twitter:title" else { continue }
            if let value = element.attributes["content"]?.collapsingWhitespace(), !value.isEmpty {
                return value
            }
        }

        for element in root.descendants where element.name == "title" {
            let value = element.text
            if !value.isEmpty { return value }
        }

        for element in root.descendants where element.name == "h1" {
            let value = element.text
            if !value.isEmpty { return value }
        }

        return nil
    }
}
