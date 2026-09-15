import Foundation

/// Serialises a parsed element back to HTML, keeping only what is safe to render.
///
/// This is the security boundary for full-page content. Feed HTML comes from a server the user
/// chose to trust; a fetched page is arbitrary markup from whoever the link points at, rendered in
/// a web view that can reach the network. So the rules are an allowlist, not a blocklist:
///
/// - Only known-inert elements survive. An unknown element is *unwrapped* rather than dropped, so
///   text inside a `<custom-block>` is kept while the element itself is not.
/// - Only named attributes survive per element. That removes `on*` handlers wholesale, along with
///   `style` (which can position content over the app's own chrome) and `class`/`id`.
/// - URL attributes are resolved against the page and restricted by scheme, so `javascript:` and
///   `data:text/html` cannot reach the renderer.
///
/// ``ArticleExtractor`` has already dropped `<script>`, `<iframe>`, `<form>` and friends with
/// their contents. This layer is the second half of the same guarantee: even if a stripping rule
/// is one day loosened, nothing executable can be serialised.
public enum HTMLSanitizer {

    /// Elements kept as themselves.
    static let allowedTags: Set<String> = [
        "p", "br", "hr", "div", "span", "section", "article", "main",
        "h1", "h2", "h3", "h4", "h5", "h6",
        "ul", "ol", "li", "dl", "dt", "dd",
        "blockquote", "pre", "code", "kbd", "samp", "var",
        "em", "strong", "i", "b", "u", "s", "del", "ins", "sub", "sup", "small", "mark",
        "a", "img", "picture", "source", "figure", "figcaption", "video", "audio",
        "table", "thead", "tbody", "tfoot", "tr", "td", "th", "caption", "colgroup", "col",
        "abbr", "cite", "q", "time", "address", "ruby", "rt", "rp", "bdi", "bdo", "wbr",
    ]

    /// Attributes kept, per element. Anything not listed is dropped.
    static let allowedAttributes: [String: Set<String>] = [
        "a": ["href", "title"],
        "img": ["src", "srcset", "sizes", "alt", "title", "width", "height", "loading"],
        "source": ["src", "srcset", "sizes", "type", "media"],
        "video": ["src", "poster", "controls", "width", "height"],
        "audio": ["src", "controls"],
        "td": ["colspan", "rowspan"],
        "th": ["colspan", "rowspan", "scope"],
        "col": ["span"],
        "colgroup": ["span"],
        "time": ["datetime"],
        "blockquote": ["cite"],
        "q": ["cite"],
        "abbr": ["title"],
        "bdo": ["dir"],
        "ol": ["start", "reversed", "type"],
    ]

    /// Attributes holding a single URL, which must be resolved and scheme-checked.
    private static let urlAttributes: Set<String> = ["href", "src", "poster", "cite"]

    /// Schemes a link may point at. `javascript:` is absent by construction.
    private static let allowedLinkSchemes: Set<String> = ["http", "https", "mailto", "tel"]

    /// Schemes a subresource may load. `data:` is excluded even for images: a `data:text/html`
    /// payload in an `<img src>` is inert, but allowing the scheme at all invites the next
    /// attribute to be less careful.
    private static let allowedResourceSchemes: Set<String> = ["http", "https"]

    /// Serialises an element and its subtree.
    public static func sanitize(_ element: HTMLElement, baseURL: URL?) -> String {
        var output = ""
        write(.element(element), baseURL: baseURL, into: &output)
        return output
    }

    // MARK: - Private

    private static func write(_ node: HTMLNode, baseURL: URL?, into output: inout String) {
        switch node {
        case .text(let value):
            output += escapingText(HTMLEntities.decoding(value))

        case .element(let element):
            guard !ArticleExtractor.discardedTags.contains(element.name) else { return }

            guard allowedTags.contains(element.name) else {
                // Unwrapped, not dropped: an unrecognised wrapper is far more likely to be a
                // custom element around real prose than to be furniture.
                for child in element.children {
                    write(child, baseURL: baseURL, into: &output)
                }
                return
            }

            if element.name == "img", isTrackingPixel(element) { return }

            let attributes = keptAttributes(of: element, baseURL: baseURL)
            let rendered = attributes
                .sorted { $0.key < $1.key }
                .map { $0.value.isEmpty ? " \($0.key)" : " \($0.key)=\"\(escapingAttribute($0.value))\"" }
                .joined()

            if HTMLTags.void.contains(element.name) {
                output += "<\(element.name)\(rendered)>"
                return
            }

            output += "<\(element.name)\(rendered)>"
            for child in element.children {
                write(child, baseURL: baseURL, into: &output)
            }
            output += "</\(element.name)>"
        }
    }

    private static func keptAttributes(of element: HTMLElement, baseURL: URL?) -> [String: String] {
        let allowed = allowedAttributes[element.name] ?? []
        var kept: [String: String] = [:]

        for (name, value) in element.attributes where allowed.contains(name) {
            if name == "srcset" {
                let resolved = resolvingSourceSet(value, baseURL: baseURL)
                if !resolved.isEmpty { kept[name] = resolved }
                continue
            }
            if urlAttributes.contains(name) {
                let schemes = name == "href" ? allowedLinkSchemes : allowedResourceSchemes
                guard let url = resolving(value, baseURL: baseURL, allowing: schemes) else { continue }
                kept[name] = url
                continue
            }
            kept[name] = value
        }

        // Lazily loaded images carry a placeholder in `src` and the real file in `data-src`, so
        // without this the article renders a column of grey 1×1 spacers where its pictures were.
        if element.name == "img", kept["src"] == nil, kept["srcset"] == nil {
            for candidate in ["data-src", "data-original", "data-lazy-src"] {
                if let value = element.attributes[candidate],
                   let url = resolving(value, baseURL: baseURL, allowing: allowedResourceSchemes) {
                    kept["src"] = url
                    break
                }
            }
            if kept["src"] == nil, let value = element.attributes["data-srcset"] {
                let resolved = resolvingSourceSet(value, baseURL: baseURL)
                if !resolved.isEmpty { kept["srcset"] = resolved }
            }
        }

        // An anchor whose href did not survive would render as underlined text that does nothing.
        if element.name == "a", kept["href"] == nil {
            kept.removeValue(forKey: "title")
        }

        return kept
    }

    /// Resolves a URL against the page and checks its scheme.
    private static func resolving(_ value: String, baseURL: URL?, allowing schemes: Set<String>) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Checked on the raw string as well as the parsed URL: `URL` is lenient about leading
        // whitespace and control characters, which is the classic way a `javascript:` URL slips
        // past a scheme check.
        let lowered = trimmed.lowercased()
        guard !lowered.hasPrefix("javascript:"), !lowered.hasPrefix("vbscript:"),
              !lowered.hasPrefix("data:"), !lowered.hasPrefix("file:"),
              !lowered.hasPrefix("about:") else { return nil }

        guard let url = URL(string: trimmed, relativeTo: baseURL)?.absoluteURL,
              let scheme = url.scheme?.lowercased(),
              schemes.contains(scheme) else { return nil }

        return url.absoluteString
    }

    /// Resolves each candidate in a `srcset`, dropping any that fail the scheme check.
    private static func resolvingSourceSet(_ value: String, baseURL: URL?) -> String {
        value
            .split(separator: ",")
            .compactMap { candidate -> String? in
                let parts = candidate.split(separator: " ", omittingEmptySubsequences: true)
                guard let first = parts.first,
                      let url = resolving(String(first), baseURL: baseURL, allowing: allowedResourceSchemes)
                else { return nil }
                let descriptor = parts.dropFirst().joined(separator: " ")
                return descriptor.isEmpty ? url : "\(url) \(descriptor)"
            }
            .joined(separator: ", ")
    }

    /// A 1×1 image is a tracking beacon, not a picture.
    ///
    /// Worth the special case because extraction is meant to leave the page's telemetry behind,
    /// and a beacon inside the article body would otherwise be fetched the moment the pane renders.
    private static func isTrackingPixel(_ element: HTMLElement) -> Bool {
        guard let width = Int(element.attributes["width"] ?? ""),
              let height = Int(element.attributes["height"] ?? "") else { return false }
        return width <= 2 && height <= 2
    }

    private static func escapingText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func escapingAttribute(_ value: String) -> String {
        escapingText(value)
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
