import Foundation
import ReadReadSupport

/// The text a search matches against, and the one way of making it.
///
/// ## Why it is folded when stored rather than when compared
///
/// The store can compare case- and diacritic-insensitively on its own, and that is exactly what
/// this avoids asking it to do. An insensitive `CONTAINS` has to fold both sides of every
/// comparison, over the whole body of every item in the scope, on every keystroke. Folding once on
/// the way in turns the search into a plain substring test, and folding the query the same way is
/// what makes the two sides agree: "Über" finds "uber", "STRASSE" finds "Straße".
///
/// Both sides go through ``fold(_:)`` and nothing else. Two derivations of the text is how an item
/// ends up found by one search and missed by the same words typed again.
public enum SearchText {

    /// Case, accents and full-width forms, all folded away.
    ///
    /// `locale: nil` deliberately. Folding under the current locale would make the stored text
    /// depend on the language the device was set to when the item arrived — a Turkish locale folds
    /// `I` differently — and a device switching language would then stop finding what it stored.
    public static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// The searchable text for an item's fields, folded.
    ///
    /// - Parameter body: The body as **plain text**, already stripped of markup. Taken as text
    ///   rather than HTML because the ingest planners have usually just stripped it for the excerpt,
    ///   and stripping is the expensive half of all this.
    ///
    /// The fields are joined by a line break, so that a term cannot match across the seam between
    /// the end of a title and the start of a body. No query term contains one.
    ///
    /// A body identical to the title is left out. That is every Mastodon post without a content
    /// warning — a status has no title, so its text stands in as one — and storing it twice would
    /// double the column for nothing.
    public static func make(
        title: String,
        authorName: String? = nil,
        authorHandle: String? = nil,
        body: String
    ) -> String {
        var fields = [title, authorName ?? "", authorHandle ?? ""]
        if body != title { fields.append(body) }
        return fold(fields.filter { !$0.isEmpty }.joined(separator: "\n"))
    }

    /// The searchable text for an item as it stands in the store.
    ///
    /// Strips the body itself, so it costs a full pass over the HTML. For the ingest path, where
    /// the planner has the plain text to hand, prefer ``make(title:authorName:authorHandle:body:)``.
    public static func make(for item: CachedItem) -> String {
        make(
            title: item.title,
            authorName: item.authorName,
            authorHandle: item.authorHandle,
            body: HTMLText.plainText(from: item.contentHTML)
        )
    }
}

/// What someone typed into the search field, reduced to the terms that have to match.
///
/// Every term must appear, in any order and anywhere in the item: "swift actor" finds an article
/// that says "actors in Swift". That is what a search box in a reader is expected to do, and a
/// phrase match would miss most of what the reader meant.
public struct SearchQuery: Hashable, Sendable {

    /// Folded, de-duplicated, and never empty — neither the list nor any term in it.
    ///
    /// An empty term is not harmless: the store answers `contains("")` with *false*, so one stray
    /// empty term would make every search come back with nothing.
    public let terms: [String]

    /// Nil when there is nothing to search for — an empty field, or one holding only spaces.
    public init?(_ text: String) {
        var seen: Set<String> = []
        let terms = SearchText.fold(text)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { seen.insert($0).inserted }
        guard !terms.isEmpty else { return nil }
        self.terms = terms
    }
}
