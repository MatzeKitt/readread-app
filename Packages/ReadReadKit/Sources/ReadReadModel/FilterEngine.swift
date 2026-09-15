import Foundation
import ReadReadSupport

/// The parts of an item a filter rule can inspect.
///
/// A value type rather than the model itself, so the engine can be exercised in tests without a
/// store and can evaluate an `IngestedItem` — which does not exist as a row yet — and a
/// `CachedItem` through exactly the same code path. Two evaluation paths that could disagree is
/// precisely how an item ends up hidden at ingest and visible after a re-evaluation, or the
/// reverse.
public struct FilterSubject: Sendable {

    public var title: String
    public var authorName: String?
    public var sourceTitle: String?
    public var accountID: UUID
    public var sourceID: String

    /// The body, as **HTML**.
    ///
    /// Held un-stripped on purpose. Converting it to plain text costs more than every other field
    /// of every rule put together, and most rule sets never look at the body at all — so the
    /// engine strips it lazily, once, and only when a rule that reads it is actually reached.
    public var contentHTML: String

    /// The body already stripped to plain text, when the caller has it to hand.
    ///
    /// Set, the engine uses it and never touches ``contentHTML``. Nil, it strips lazily as before.
    ///
    /// Exists for the filter editor's live preview, which re-counts the whole cache after every
    /// pause in typing. The stripping is the expensive half and its input never changes between
    /// passes — only the pattern does — so the pass that repeats is the one that can least afford
    /// to redo it. See `FilterReevaluator.matchCount(for:limit:)`.
    ///
    /// The one rule for anything filling this in: it must be `HTMLText.plainText(from:)` of the
    /// same body, and nothing else. Two ways of deriving the text a rule matches against is how an
    /// item ends up hidden by a preview and visible after the real pass.
    public var contentText: String?

    public init(
        title: String,
        authorName: String? = nil,
        sourceTitle: String? = nil,
        accountID: UUID,
        sourceID: String,
        contentHTML: String = "",
        contentText: String? = nil
    ) {
        self.title = title
        self.authorName = authorName
        self.sourceTitle = sourceTitle
        self.accountID = accountID
        self.sourceID = sourceID
        self.contentHTML = contentHTML
        self.contentText = contentText
    }

    public init(_ item: IngestedItem, sourceTitle: String? = nil) {
        self.init(
            title: item.title,
            authorName: item.authorName,
            sourceTitle: sourceTitle,
            accountID: item.accountID,
            sourceID: item.sourceID,
            contentHTML: item.contentHTML
        )
    }

    public init(_ item: CachedItem, sourceTitle: String? = nil) {
        self.init(
            title: item.title,
            authorName: item.authorName,
            sourceTitle: sourceTitle,
            accountID: item.accountID,
            sourceID: item.sourceID,
            contentHTML: item.contentHTML
        )
    }
}

/// One rule, with its pattern turned into something that can be run against text.
///
/// Compiling up front is the point of the engine: a regex costs far more to build than to run, and
/// re-evaluating a rule set over a whole store means running each rule tens of thousands of times.
public struct CompiledFilterRule: Sendable, Identifiable {

    /// How the pattern is actually executed.
    ///
    /// `NSRegularExpression` rather than Swift's `Regex`, which is not `Sendable` and so cannot be
    /// held in a value that crosses to the ingest actor.
    enum Matcher: Sendable {
        case substring(needle: String, options: String.CompareOptions)
        case regularExpression(NSRegularExpression)
    }

    public let id: UUID
    public let name: String
    public let fields: FilterFields
    public let scope: FilterScope
    let matcher: Matcher

    /// Whether this rule looks at `scope`'s item at all.
    func applies(to subject: FilterSubject) -> Bool {
        switch scope {
        case .everywhere: true
        case .account(let id): subject.accountID == id
        case .source(let id): subject.sourceID == id
        }
    }

    func matches(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }

        switch matcher {
        case .substring(let needle, let options):
            return text.range(of: needle, options: options) != nil

        case .regularExpression(let expression):
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            return expression.firstMatch(in: text, range: range) != nil
        }
    }
}

/// Compiles the enabled filter rules and decides whether an item is hidden.
///
/// Rules only ever *hide*. There is no "show only" mode, so evaluation is a plain disjunction and
/// order does not matter — which is why the engine can stop at the first rule that matches and
/// never has to reason about precedence.
public struct FilterEngine: Sendable {

    public let rules: [CompiledFilterRule]

    /// Patterns that could not be compiled, by rule id.
    ///
    /// Surfaced rather than swallowed: a regular expression is easy to get wrong, and a rule that
    /// silently stops filtering looks exactly like a rule that is working. The filter editor shows
    /// this beside the offending rule.
    public let compilationFailures: [UUID: String]

    /// Whether any enabled rule reads the item body.
    ///
    /// Checked before stripping HTML, which is the one genuinely expensive part of evaluation.
    public var inspectsContent: Bool {
        rules.contains { $0.fields.contains(.content) }
    }

    public var isEmpty: Bool { rules.isEmpty }

    public init(rules: [CompiledFilterRule], compilationFailures: [UUID: String] = [:]) {
        self.rules = rules
        self.compilationFailures = compilationFailures
    }

    /// Compiles a rule set, skipping anything disabled or empty.
    ///
    /// An invalid pattern disables **only its own rule**. The alternative — throwing — would mean
    /// one bad regex stopped every other rule from filtering, which is both surprising and, since
    /// filtering runs unattended at ingest, invisible until items you expected to be hidden pile
    /// up.
    public init(_ rules: some Sequence<FilterRule>) {
        var compiled: [CompiledFilterRule] = []
        var failures: [UUID: String] = [:]

        for rule in rules {
            guard rule.isEnabled, !rule.pattern.isEmpty, !rule.fields.isEmpty else { continue }

            do {
                compiled.append(CompiledFilterRule(
                    id: rule.id,
                    name: rule.effectiveName,
                    fields: rule.fields,
                    scope: rule.scope,
                    matcher: try Self.matcher(for: rule)
                ))
            } catch {
                failures[rule.id] = Self.describe(error)
            }
        }

        self.init(rules: compiled, compilationFailures: failures)
    }

    private static func matcher(for rule: FilterRule) throws -> CompiledFilterRule.Matcher {
        switch rule.matchKind {
        case .contains:
            return .substring(
                needle: rule.pattern,
                options: rule.isCaseSensitive ? [] : [.caseInsensitive]
            )

        case .wholeWord:
            // Expressed as a bounded regex rather than `String.CompareOptions`, because there is no
            // whole-word compare option outside of `NSString`'s literal search and the boundary has
            // to hold for Unicode letters too — otherwise "AI" would still match "Kaiser".
            let escaped = NSRegularExpression.escapedPattern(for: rule.pattern)
            return .regularExpression(try NSRegularExpression(
                pattern: "\\b\(escaped)\\b",
                options: rule.isCaseSensitive ? [] : [.caseInsensitive]
            ))

        case .regularExpression:
            return .regularExpression(try NSRegularExpression(
                pattern: rule.pattern,
                options: rule.isCaseSensitive ? [] : [.caseInsensitive]
            ))
        }
    }

    private static func describe(_ error: any Error) -> String {
        // `NSRegularExpression` reports its parse errors in `NSLocalizedDescription`, and its
        // wording ("The value “…” is invalid.") is the most useful thing available.
        (error as NSError).localizedDescription
    }

    /// The first rule that hides this item, or `nil` if none does.
    ///
    /// Returning the rule rather than a `Bool` so the "Filtered Items" list can say *why* something
    /// is hidden — the single most common question a filter raises.
    public func firstMatch(for subject: FilterSubject) -> CompiledFilterRule? {
        guard !rules.isEmpty else { return nil }

        // Stripped at most once per item, however many rules read the body, and not at all when
        // none does.
        var contentText: String?

        for rule in rules where rule.applies(to: subject) {
            if rule.fields.contains(.title), rule.matches(subject.title) {
                return rule
            }
            if rule.fields.contains(.author), let author = subject.authorName, rule.matches(author) {
                return rule
            }
            if rule.fields.contains(.sourceTitle), let source = subject.sourceTitle, rule.matches(source) {
                return rule
            }
            if rule.fields.contains(.content) {
                let text = contentText
                    ?? subject.contentText
                    ?? HTMLText.plainText(from: subject.contentHTML)
                contentText = text
                if rule.matches(text) { return rule }
            }
        }

        return nil
    }

    public func hides(_ subject: FilterSubject) -> Bool {
        firstMatch(for: subject) != nil
    }
}
