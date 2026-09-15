import Foundation

/// Converts feed HTML to plain text for list excerpts.
///
/// Hand-rolled rather than using `NSAttributedString(html:)` or `AttributedString(html:)` for two
/// reasons that rule those out entirely here: the WebKit-backed importer is documented as
/// main-thread-only, and ingest runs on a background actor over hundreds of items; and it is
/// orders of magnitude too slow for that volume even if it were thread-safe.
///
/// This does not attempt to be a general HTML parser. It only has to produce a readable one-line
/// summary from feed content, so it deliberately makes cheap, predictable choices and never fails.
public enum HTMLText {

    /// Tags whose *contents* are not prose and must be dropped wholesale, not just unwrapped.
    ///
    /// These are skipped by scanning for the literal closing tag rather than by parsing the markup
    /// in between. That is not an optimisation, it is required for correctness: `<script>` and
    /// `<style>` are raw-text elements whose bodies routinely contain `<`, and a comparison like
    /// `if (a < b)` would otherwise be parsed as a tag, consume the real `</script>` while looking
    /// for its own `>`, and leave the scanner dropping the entire rest of the document.
    private static let contentBearingTagsToDrop: Set<String> = ["script", "style", "head", "svg"]

    /// Tags that imply a break between words. Without this, `<p>one</p><p>two</p>` would render as
    /// `onetwo`.
    private static let breakingTags: Set<String> = [
        "p", "br", "div", "li", "tr", "td", "th", "h1", "h2", "h3", "h4", "h5", "h6",
        "blockquote", "pre", "section", "article", "header", "footer", "figcaption", "hr",
    ]

    /// Strips markup and decodes entities, collapsing all runs of whitespace to single spaces.
    public static func plainText(from html: String) -> String {
        var output = ""
        output.reserveCapacity(html.count)

        var index = html.startIndex

        while index < html.endIndex {
            let character = html[index]

            guard character == "<" else {
                output.append(character)
                index = html.index(after: index)
                continue
            }

            // Find the end of the tag. An unterminated `<` is literal text, not a tag — feed
            // content contains plenty of stray angle brackets.
            guard let tagEnd = html[index...].firstIndex(of: ">") else {
                output.append(contentsOf: html[index...])
                break
            }

            let tagBody = html[html.index(after: index)..<tagEnd]
            let isClosing = tagBody.hasPrefix("/")
            let name = tagName(in: tagBody)
            let afterTag = html.index(after: tagEnd)

            // A self-closing `<svg/>` has no contents and no close tag, so it must not start a
            // skip that would then run to the end of the document.
            if !isClosing, !tagBody.hasSuffix("/"), contentBearingTagsToDrop.contains(name) {
                index = indexAfterClosingTag(named: name, in: html, from: afterTag) ?? html.endIndex
                continue
            }

            if breakingTags.contains(name) {
                output.append(" ")
            }
            index = afterTag
        }

        return collapsingWhitespace(in: decodingEntities(in: output))
    }

    /// Produces a list excerpt: plain text, truncated on a word boundary with an ellipsis.
    ///
    /// - Parameter limit: Maximum characters. The default comfortably overfills three lines at any
    ///   Dynamic Type size, so the view can decide the real line count with `lineLimit(3)` while
    ///   the stored string stays small.
    public static func excerpt(from html: String, limit: Int = 320) -> String {
        truncating(plainText(from: html), to: limit)
    }

    /// Truncates plain text at a word boundary, appending an ellipsis only if text was removed.
    public static func truncating(_ text: String, to limit: Int) -> String {
        guard limit > 0 else { return "" }
        guard text.count > limit else { return text }

        let cutoff = text.index(text.startIndex, offsetBy: limit)
        let head = text[text.startIndex..<cutoff]

        // The cut may already fall between words, in which case `head` is a whole number of words
        // and backing up would throw one away for nothing.
        if text[cutoff].isWhitespace {
            return head + "…"
        }

        // Otherwise back up to the last space so a word is not sliced in half. If the whole window
        // is one long token (a URL, say) there is no useful boundary, so hard-cut instead of
        // returning a stub.
        if let lastSpace = head.lastIndex(of: " ") {
            let trimmed = text[text.startIndex..<lastSpace]
            if trimmed.count >= limit / 2 {
                return trimmed + "…"
            }
        }
        return head + "…"
    }

    // MARK: - Private

    /// Finds the position just past `</name ... >`, searching the raw text so that `<` characters
    /// inside the skipped element cannot be mistaken for markup.
    ///
    /// Returns `nil` when the document ends without the closing tag — a truncated feed — in which
    /// case the remainder genuinely is inside the element and dropping it is correct.
    private static func indexAfterClosingTag(
        named name: String,
        in html: String,
        from start: String.Index
    ) -> String.Index? {
        var searchStart = start

        while searchStart < html.endIndex {
            guard let match = html.range(
                of: "</\(name)",
                options: [.caseInsensitive],
                range: searchStart..<html.endIndex
            ) else {
                return nil
            }

            // Require a delimiter after the name so `</scriptfoo>` is not treated as `</script>`.
            let afterName = match.upperBound
            let isDelimited = afterName == html.endIndex
                || html[afterName] == ">"
                || html[afterName].isWhitespace
                || html[afterName] == "/"

            if isDelimited, let tagEnd = html[afterName...].firstIndex(of: ">") {
                return html.index(after: tagEnd)
            }

            searchStart = afterName
        }

        return nil
    }

    /// Extracts the lowercased element name from the inside of a tag, e.g. `/p ` or `a href="x"`.
    private static func tagName(in tagBody: Substring) -> String {
        var body = tagBody
        if body.hasPrefix("/") {
            body = body.dropFirst()
        }
        let name = body.prefix { $0.isLetter || $0.isNumber }
        return name.lowercased()
    }

    /// Collapses every run of whitespace — including the newlines and indentation that feed HTML is
    /// full of — into a single space, and trims the ends.
    private static func collapsingWhitespace(in text: String) -> String {
        var output = ""
        output.reserveCapacity(text.count)
        var previousWasWhitespace = false

        for character in text {
            if character.isWhitespace {
                if !previousWasWhitespace, !output.isEmpty {
                    output.append(" ")
                }
                previousWasWhitespace = true
            } else {
                output.append(character)
                previousWasWhitespace = false
            }
        }

        if output.hasSuffix(" ") {
            output.removeLast()
        }
        return output
    }

    private static func decodingEntities(in text: String) -> String {
        HTMLEntities.decoding(text)
    }
}
