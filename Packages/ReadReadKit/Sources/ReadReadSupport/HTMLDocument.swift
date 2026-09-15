import Foundation

/// One node of a parsed HTML document.
///
/// Deliberately not `Sendable`. A parsed tree is mutable and full of parent back pointers, so it
/// stays on whichever isolation domain parsed it; only the extracted ``ExtractedArticle`` — plain
/// strings — crosses a boundary.
public enum HTMLNode {
    case element(HTMLElement)
    case text(String)
}

/// An element in a parsed HTML document.
///
/// A class rather than a struct because scoring walks *upwards*: readability-style extraction
/// credits a paragraph's score to its parent and grandparent, which needs identity and a back
/// pointer. A value tree would force every score update to rebuild the path to the root.
public final class HTMLElement {

    public let name: String
    public var attributes: [String: String]
    public var children: [HTMLNode] = []

    /// Weak, so the tree does not retain itself through the parent/child cycle.
    public weak var parent: HTMLElement?

    init(name: String, attributes: [String: String] = [:]) {
        self.name = name
        self.attributes = attributes
    }

    public func append(_ node: HTMLNode) {
        if case .element(let child) = node {
            child.parent = self
        }
        children.append(node)
    }

    public var childElements: [HTMLElement] {
        children.compactMap { if case .element(let element) = $0 { element } else { nil } }
    }

    /// Every element beneath this one, in document order, this one excluded.
    public var descendants: [HTMLElement] {
        var found: [HTMLElement] = []
        var stack = childElements.reversed().map { $0 }
        while let next = stack.popLast() {
            found.append(next)
            stack.append(contentsOf: next.childElements.reversed())
        }
        return found
    }

    /// The element's text with entities decoded and whitespace collapsed.
    public var text: String {
        var output = ""
        collectText(into: &output)
        return HTMLEntities.decoding(output).collapsingWhitespace()
    }

    private func collectText(into output: inout String) {
        for child in children {
            switch child {
            case .text(let value):
                output += value
            case .element(let element):
                // Block boundaries are word boundaries; without this `<p>one</p><p>two</p>`
                // measures as one long word and scores as denser prose than it is.
                if HTMLTags.breaking.contains(element.name) { output += " " }
                element.collectText(into: &output)
                if HTMLTags.breaking.contains(element.name) { output += " " }
            }
        }
    }

    /// Removes this element from its parent.
    public func removeFromParent() {
        guard let parent else { return }
        parent.children.removeAll { node in
            if case .element(let element) = node { return element === self }
            return false
        }
        self.parent = nil
    }

    /// The element's siblings, itself excluded.
    public var siblings: [HTMLElement] {
        (parent?.childElements ?? []).filter { $0 !== self }
    }

    public func attribute(_ name: String) -> String? {
        attributes[name]
    }

    /// `class` and `id` joined, lowercased — what the extractor's positive and negative signals
    /// are matched against.
    public var classAndID: String {
        ((attributes["class"] ?? "") + " " + (attributes["id"] ?? "")).lowercased()
    }
}

/// Tag classifications shared by the parser, the text extractor and the sanitiser.
public enum HTMLTags {

    /// Elements with no closing tag.
    public static let void: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input",
        "link", "meta", "param", "source", "track", "wbr",
    ]

    /// Elements whose content is raw text, not markup.
    ///
    /// These must be consumed by scanning for the literal close tag: `<script>` bodies routinely
    /// contain `<`, and parsing `if (a < b)` as a tag would swallow the real `</script>` and
    /// derail the rest of the document.
    public static let rawText: Set<String> = ["script", "style", "textarea", "title", "noscript"]

    /// Elements that imply a break between words when flattening to text.
    public static let breaking: Set<String> = [
        "p", "br", "div", "li", "tr", "td", "th", "h1", "h2", "h3", "h4", "h5", "h6",
        "blockquote", "pre", "section", "article", "header", "footer", "figcaption", "hr",
        "ul", "ol", "dl", "dt", "dd", "table", "aside", "nav", "main", "figure",
    ]

    /// Start tags that implicitly close an open `<p>`.
    ///
    /// Unclosed `<p>` is not an edge case — it is legal HTML and extremely common — and without
    /// this every following block nests inside the first paragraph, which collapses the tree into
    /// one candidate and makes density scoring meaningless.
    static let closesParagraph: Set<String> = [
        "address", "article", "aside", "blockquote", "div", "dl", "fieldset", "figcaption",
        "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr",
        "main", "nav", "ol", "p", "pre", "section", "table", "ul", "li",
    ]
}

/// A deliberately small, never-failing HTML parser.
///
/// Not a spec-compliant HTML5 tree builder — it implements only the implicit-close rules that
/// real-world pages actually rely on. Correctness here is measured by whether the resulting tree
/// supports density scoring, not by conformance: a slightly wrong nesting inside a `<table>` costs
/// nothing, whereas failing to parse a page at all costs the whole feature.
public enum HTMLParser {

    /// Parses a document and returns a synthetic root element containing it.
    public static func parse(_ html: String) -> HTMLElement {
        let root = HTMLElement(name: "#root")
        var stack = [root]
        var index = html.startIndex

        func current() -> HTMLElement { stack[stack.count - 1] }

        while index < html.endIndex {
            guard let markup = html[index...].firstIndex(of: "<") else {
                appendText(String(html[index...]), to: current())
                break
            }

            if markup > index {
                appendText(String(html[index..<markup]), to: current())
            }

            let afterAngle = html.index(after: markup)
            guard afterAngle < html.endIndex else {
                appendText("<", to: current())
                break
            }

            // Comments and doctypes carry nothing worth keeping.
            if html[afterAngle...].hasPrefix("!--") {
                index = skip(from: afterAngle, to: "-->", in: html)
                continue
            }
            if html[afterAngle] == "!" || html[afterAngle] == "?" {
                index = skip(from: afterAngle, to: ">", in: html)
                continue
            }

            guard let tagEnd = endOfTag(in: html, from: afterAngle) else {
                // An unterminated `<` this late in a document is text, not markup.
                appendText(String(html[markup...]), to: current())
                break
            }

            let body = html[afterAngle..<tagEnd]
            index = html.index(after: tagEnd)

            if body.hasPrefix("/") {
                let name = tagName(body.dropFirst())
                guard !name.isEmpty else { continue }
                // Pop to the nearest matching element. A close tag with nothing open to match is
                // simply stray markup and is ignored rather than unwinding the whole document.
                if let position = stack.lastIndex(where: { $0.name == name }), position > 0 {
                    stack.removeSubrange(position...)
                }
                continue
            }

            let name = tagName(body)
            guard !name.isEmpty else { continue }
            let attributes = parseAttributes(in: body.drop { !$0.isWhitespace })
            let isSelfClosing = body.hasSuffix("/")

            closeImplicitly(before: name, stack: &stack)

            let element = HTMLElement(name: name, attributes: attributes)
            current().append(.element(element))

            if HTMLTags.void.contains(name) || isSelfClosing {
                continue
            }

            if HTMLTags.rawText.contains(name) {
                let (raw, next) = rawContent(named: name, in: html, from: index)
                // Kept as text so `<title>` and `<textarea>` still read; `<script>` and `<style>`
                // are dropped wholesale by the extractor before any of this is used.
                if !raw.isEmpty { element.append(.text(raw)) }
                index = next
                continue
            }

            stack.append(element)
        }

        return root
    }

    // MARK: - Private

    /// Finds the `>` that closes a tag, ignoring any inside a quoted attribute value.
    ///
    /// Naively taking the first `>` is wrong in a way that is invisible until it is not: an
    /// attribute like Wikipedia's `data-mw='{"wt":"<code>x</code>"}'` holds angle brackets, so the
    /// tag is cut short mid-attribute and everything after it — a page's worth of template JSON —
    /// is emitted as body text. HTML5 agrees: a quoted value ends only at its own quote.
    private static func endOfTag(in html: String, from start: String.Index) -> String.Index? {
        var index = start
        var quote: Character?

        while index < html.endIndex {
            let character = html[index]

            if let open = quote {
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == ">" {
                return index
            }
            index = html.index(after: index)
        }

        return nil
    }

    private static func appendText(_ text: String, to element: HTMLElement) {
        guard !text.isEmpty else { return }
        element.append(.text(text))
    }

    private static func skip(from start: String.Index, to terminator: String, in html: String) -> String.Index {
        guard let range = html.range(of: terminator, range: start..<html.endIndex) else {
            return html.endIndex
        }
        return range.upperBound
    }

    /// Applies the handful of implicit-close rules that matter in practice.
    private static func closeImplicitly(before name: String, stack: inout [HTMLElement]) {
        func close(_ names: Set<String>) {
            while stack.count > 1, names.contains(stack[stack.count - 1].name) {
                stack.removeLast()
            }
        }

        switch name {
        case "li":
            close(["p", "li"])
        case "dt", "dd":
            close(["p", "dt", "dd"])
        case "td", "th":
            close(["p", "td", "th"])
        case "tr":
            close(["p", "td", "th", "tr"])
        case "tbody", "tfoot", "thead":
            close(["p", "td", "th", "tr", "tbody", "thead"])
        case "option":
            close(["option"])
        default:
            if HTMLTags.closesParagraph.contains(name) {
                close(["p"])
            }
        }
    }

    private static func tagName(_ body: Substring) -> String {
        body.prefix { $0.isLetter || $0.isNumber }.lowercased()
    }

    /// Consumes a raw-text element's body by searching for its literal close tag.
    private static func rawContent(
        named name: String,
        in html: String,
        from start: String.Index
    ) -> (String, String.Index) {
        var searchStart = start

        while searchStart < html.endIndex {
            guard let match = html.range(
                of: "</\(name)",
                options: [.caseInsensitive],
                range: searchStart..<html.endIndex
            ) else {
                break
            }

            // Require a delimiter, so `</scriptlet>` does not end a `<script>`.
            let afterName = match.upperBound
            let delimited = afterName == html.endIndex
                || html[afterName] == ">"
                || html[afterName] == "/"
                || html[afterName].isWhitespace

            if delimited, let tagEnd = html[afterName...].firstIndex(of: ">") {
                return (String(html[start..<match.lowerBound]), html.index(after: tagEnd))
            }
            searchStart = afterName
        }

        // A truncated document: the rest genuinely is inside the element.
        return (String(html[start...]), html.endIndex)
    }

    /// Parses `key`, `key=value`, `key="value"` and `key='value'`, lowercasing names.
    private static func parseAttributes(in body: Substring) -> [String: String] {
        var attributes: [String: String] = [:]
        var index = body.startIndex

        while index < body.endIndex {
            while index < body.endIndex, body[index].isWhitespace || body[index] == "/" {
                index = body.index(after: index)
            }
            guard index < body.endIndex else { break }

            let nameStart = index
            while index < body.endIndex, !body[index].isWhitespace, body[index] != "=", body[index] != "/" {
                index = body.index(after: index)
            }
            let name = body[nameStart..<index].lowercased()
            guard !name.isEmpty else {
                if index < body.endIndex { index = body.index(after: index) }
                continue
            }

            while index < body.endIndex, body[index].isWhitespace {
                index = body.index(after: index)
            }

            guard index < body.endIndex, body[index] == "=" else {
                // A bare attribute (`disabled`, `hidden`) is present with an empty value.
                attributes[name] = ""
                continue
            }

            index = body.index(after: index)
            while index < body.endIndex, body[index].isWhitespace {
                index = body.index(after: index)
            }
            guard index < body.endIndex else {
                attributes[name] = ""
                break
            }

            let quote = body[index]
            if quote == "\"" || quote == "'" {
                index = body.index(after: index)
                let valueStart = index
                while index < body.endIndex, body[index] != quote {
                    index = body.index(after: index)
                }
                attributes[name] = HTMLEntities.decoding(String(body[valueStart..<index]))
                if index < body.endIndex { index = body.index(after: index) }
            } else {
                let valueStart = index
                while index < body.endIndex, !body[index].isWhitespace {
                    index = body.index(after: index)
                }
                attributes[name] = HTMLEntities.decoding(String(body[valueStart..<index]))
            }
        }

        return attributes
    }
}

extension String {

    /// Collapses every run of whitespace to a single space and trims the ends.
    func collapsingWhitespace() -> String {
        var output = ""
        output.reserveCapacity(count)
        var previousWasWhitespace = false

        for character in self {
            if character.isWhitespace {
                if !previousWasWhitespace, !output.isEmpty { output.append(" ") }
                previousWasWhitespace = true
            } else {
                output.append(character)
                previousWasWhitespace = false
            }
        }

        while output.hasSuffix(" ") { output.removeLast() }
        return output
    }
}
