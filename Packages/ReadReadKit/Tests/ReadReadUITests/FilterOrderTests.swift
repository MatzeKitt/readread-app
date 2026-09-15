import Foundation
import ReadReadModel
import Testing

@testable import ReadReadUI

/// The order the rule list is shown in.
///
/// `@MainActor` because `FilterListView` is a `View`, and SwiftUI's `View` carries main-actor
/// isolation onto the whole conforming type, static helpers included.
@Suite("Filter order")
@MainActor
struct FilterOrderTests {

    /// Rules are created in whatever order the reader happened to add them, which is what the list
    /// used to show. `createdAt` is spread apart so the tiebreak is deterministic.
    private func rule(name: String = "", pattern: String, age: TimeInterval = 0) -> FilterRule {
        FilterRule(
            name: name,
            pattern: pattern,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000 + age)
        )
    }

    @Test("Named rules sort by their name")
    func namedRulesSortByName() {
        let rules = [
            rule(name: "Sport", pattern: "football"),
            rule(name: "Ads", pattern: "sponsored"),
            rule(name: "Politics", pattern: "election"),
        ]

        #expect(FilterListView.sorted(rules).map(\.effectiveName) == ["Ads", "Politics", "Sport"])
    }

    /// The reason this cannot be a `SortDescriptor` in the `@Query`: an unnamed rule shows its
    /// *pattern*, so sorting on the stored `name` would file every unnamed rule together under the
    /// empty string and leave the visible list looking unsorted.
    @Test("An unnamed rule sorts by the pattern it shows")
    func unnamedRulesSortByPattern() {
        let rules = [
            rule(name: "Middle", pattern: "zzz"),
            rule(pattern: "aardvark"),
            rule(pattern: "zebra"),
        ]

        #expect(
            FilterListView.sorted(rules).map(\.effectiveName) == ["aardvark", "Middle", "zebra"]
        )
    }

    /// `<` on `String` compares Unicode scalars, which files every capital ahead of every lowercase
    /// letter — "Zeit" before "ansehen" — and sorts „Ärger" after "Zeit".
    @Test("Case and diacritics sort the way a person would file them")
    func caseAndDiacriticsSortNaturally() {
        let rules = [
            rule(pattern: "Zeit"),
            rule(pattern: "ansehen"),
            rule(pattern: "Ärger"),
            rule(pattern: "Beitrag"),
        ]

        #expect(
            FilterListView.sorted(rules).map(\.effectiveName)
                == ["ansehen", "Ärger", "Beitrag", "Zeit"]
        )
    }

    /// The Finder's ordering, which reads a run of digits as a number.
    @Test("Numbers in names count as numbers")
    func numbersSortNumerically() {
        let rules = [rule(pattern: "Rule 10"), rule(pattern: "Rule 9"), rule(pattern: "Rule 1")]

        #expect(
            FilterListView.sorted(rules).map(\.effectiveName) == ["Rule 1", "Rule 9", "Rule 10"]
        )
    }

    /// Two rules can legitimately share a label. Without a tiebreak those two could swap places on
    /// every redraw, and a row that moves under the pointer is how the wrong rule gets deleted.
    @Test("Rules with the same label keep a stable order")
    func duplicateLabelsAreStable() {
        let older = rule(name: "Ads", pattern: "one", age: 0)
        let newer = rule(name: "Ads", pattern: "two", age: 100)

        #expect(FilterListView.sorted([newer, older]).map(\.pattern) == ["one", "two"])
        #expect(FilterListView.sorted([older, newer]).map(\.pattern) == ["one", "two"])
    }

    @Test("An empty list sorts to an empty list")
    func emptyStaysEmpty() {
        #expect(FilterListView.sorted([]).isEmpty)
    }
}
