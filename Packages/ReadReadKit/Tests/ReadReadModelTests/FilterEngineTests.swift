import Foundation
import Testing

@testable import ReadReadModel

@Suite("FilterEngine")
struct FilterEngineTests {

    private let accountID = UUID()

    private func subject(
        title: String = "",
        author: String? = nil,
        sourceTitle: String? = nil,
        contentHTML: String = "",
        accountID: UUID? = nil,
        sourceID: String = "feed/1"
    ) -> FilterSubject {
        FilterSubject(
            title: title,
            authorName: author,
            sourceTitle: sourceTitle,
            accountID: accountID ?? self.accountID,
            sourceID: sourceID,
            contentHTML: contentHTML
        )
    }

    // MARK: - Match kinds

    @Test("A substring rule is case-insensitive unless it is told otherwise")
    func substringCasing() {
        let insensitive = FilterEngine([FilterRule(pattern: "crypto", fields: .title)])
        #expect(insensitive.hides(subject(title: "The Crypto Bubble")))

        let sensitive = FilterEngine([
            FilterRule(pattern: "crypto", fields: .title, isCaseSensitive: true),
        ])
        #expect(!sensitive.hides(subject(title: "The Crypto Bubble")))
        #expect(sensitive.hides(subject(title: "the crypto bubble")))
    }

    @Test("A whole-word rule does not match inside a longer word")
    func wholeWord() {
        let engine = FilterEngine([
            FilterRule(pattern: "AI", fields: .title, matchKind: .wholeWord),
        ])

        #expect(engine.hides(subject(title: "AI eats the world")))
        #expect(engine.hides(subject(title: "Notes on ai, briefly")))
        // The exact failure the whole-word mode exists for: "contains" would hide both of these.
        #expect(!engine.hides(subject(title: "Said the Kaiser")))
        #expect(!engine.hides(subject(title: "A fresh coat of paint")))
    }

    @Test("A regular-expression rule matches on its own terms")
    func regularExpression() {
        let engine = FilterEngine([
            FilterRule(pattern: "^Sponsored:", fields: .title, matchKind: .regularExpression),
        ])

        #expect(engine.hides(subject(title: "Sponsored: a fine widget")))
        #expect(!engine.hides(subject(title: "Not Sponsored: a fine widget")))
    }

    @Test("An unparseable pattern disables only its own rule")
    func invalidPatternIsIsolated() {
        let broken = FilterRule(pattern: "([unclosed", fields: .title, matchKind: .regularExpression)
        let working = FilterRule(pattern: "widget", fields: .title)

        let engine = FilterEngine([broken, working])

        #expect(engine.compilationFailures[broken.id] != nil)
        #expect(engine.compilationFailures[working.id] == nil)
        // The whole point: one bad regex must not stop every other rule from filtering, because
        // filtering runs unattended and the symptom would be invisible.
        #expect(engine.hides(subject(title: "A fine widget")))
        #expect(engine.rules.count == 1)
    }

    // MARK: - Fields

    @Test("A rule only looks at the fields it was given")
    func fieldsAreRespected() {
        let titleOnly = FilterEngine([FilterRule(pattern: "widget", fields: .title)])
        #expect(!titleOnly.hides(subject(title: "Nothing here", contentHTML: "<p>a widget</p>")))

        let contentOnly = FilterEngine([FilterRule(pattern: "widget", fields: .content)])
        #expect(contentOnly.hides(subject(title: "Nothing here", contentHTML: "<p>a widget</p>")))
        #expect(!contentOnly.hides(subject(title: "a widget")))
    }

    @Test("Content is matched as text, not as markup")
    func contentIsStripped() {
        let engine = FilterEngine([FilterRule(pattern: "img", fields: .content)])

        // A rule against the raw HTML would hide every article carrying a picture. That the body is
        // stripped first is the difference between a usable content filter and a trap.
        #expect(!engine.hides(subject(contentHTML: "<p>Text<img src=\"a.png\"></p>")))
        #expect(engine.hides(subject(contentHTML: "<p>The img element</p>")))
    }

    @Test("Author and source name are matched when asked for")
    func authorAndSource() {
        let engine = FilterEngine([
            FilterRule(pattern: "Anon", fields: .author),
            FilterRule(pattern: "Tabloid", fields: .sourceTitle),
        ])

        #expect(engine.hides(subject(author: "Anon")))
        #expect(engine.hides(subject(sourceTitle: "Daily Tabloid")))
        #expect(!engine.hides(subject(title: "Anon and the Tabloid")))
    }

    // MARK: - Scope

    @Test("A scoped rule ignores everything outside its scope")
    func scoping() {
        let otherAccount = UUID()
        let engine = FilterEngine([
            FilterRule(pattern: "widget", fields: .title, scope: .source("feed/1")),
            FilterRule(pattern: "gadget", fields: .title, scope: .account(otherAccount)),
        ])

        #expect(engine.hides(subject(title: "A widget", sourceID: "feed/1")))
        #expect(!engine.hides(subject(title: "A widget", sourceID: "feed/2")))

        #expect(!engine.hides(subject(title: "A gadget")))
        #expect(engine.hides(subject(title: "A gadget", accountID: otherAccount)))
    }

    // MARK: - Rule set

    @Test("Disabled and empty rules are not compiled")
    func skippedRules() {
        let engine = FilterEngine([
            FilterRule(pattern: "widget", fields: .title, isEnabled: false),
            FilterRule(pattern: "", fields: .title),
            FilterRule(pattern: "gadget", fields: []),
        ])

        #expect(engine.isEmpty)
        #expect(!engine.hides(subject(title: "A widget gadget")))
    }

    @Test("The matching rule is reported, so the hidden list can say why")
    func firstMatchIsNamed() {
        let engine = FilterEngine([
            FilterRule(name: "No sport", pattern: "football", fields: .title),
        ])

        let match = engine.firstMatch(for: subject(title: "Football results"))
        #expect(match?.name == "No sport")
    }

    @Test("Whether the body is read at all is knowable without reading it")
    func inspectsContent() {
        // Load-bearing: the re-evaluation pass uses this to decide whether to fault every article's
        // HTML into memory, so a wrong answer is either a broken filter or a very slow one.
        #expect(!FilterEngine([FilterRule(pattern: "x", fields: .title)]).inspectsContent)
        #expect(FilterEngine([FilterRule(pattern: "x", fields: [.title, .content])]).inspectsContent)
    }
}
