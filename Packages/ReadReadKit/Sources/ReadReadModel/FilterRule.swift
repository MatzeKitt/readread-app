import Foundation
import SwiftData

/// Which parts of an item a rule inspects.
///
/// An `OptionSet` because a rule commonly targets several fields at once ("hide anything mentioning
/// this in the title *or* body"), and because the whole set stores as one integer attribute.
public struct FilterFields: OptionSet, Hashable, Sendable, Codable {

    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let title = FilterFields(rawValue: 1 << 0)
    public static let content = FilterFields(rawValue: 1 << 1)
    public static let author = FilterFields(rawValue: 1 << 2)
    public static let sourceTitle = FilterFields(rawValue: 1 << 3)

    public static let titleAndContent: FilterFields = [.title, .content]
    public static let all: FilterFields = [.title, .content, .author, .sourceTitle]
}

/// How a rule's pattern is matched.
public enum FilterMatchKind: String, Hashable, Sendable, Codable, CaseIterable {

    /// Plain substring search. The default because it is what people mean by "ignore items
    /// containing X".
    case contains

    /// Substring search constrained to word boundaries, so `ai` does not match `said` or `paint`.
    case wholeWord

    /// Full `NSRegularExpression`. Powerful and easy to get wrong, so an invalid pattern must
    /// disable only its own rule rather than break filtering entirely.
    case regularExpression

    public var displayName: String {
        switch self {
        case .contains: String(localized: "Contains")
        case .wholeWord: String(localized: "Whole word")
        case .regularExpression: String(localized: "Regular expression")
        }
    }
}

/// Where a rule applies.
public enum FilterScope: Hashable, Sendable, Codable {
    case everywhere
    case account(UUID)
    case source(String)
}

/// A user-defined rule that hides matching items.
///
/// Rules only ever *hide*. There is no "show only" mode, because combining positive and negative
/// rules raises precedence questions that are hard to express in a UI and harder to predict.
@Model
public final class FilterRule {

    #Unique<FilterRule>([\.id])
    public var id: UUID = UUID()

    /// What the user calls this rule. Empty is allowed; the UI falls back to showing the pattern.
    public var name: String = ""

    public var pattern: String = ""

    /// `FilterFields.rawValue`.
    public var fieldsRaw: Int = FilterFields.titleAndContent.rawValue

    /// `FilterMatchKind.rawValue`.
    public var matchKindRaw: String = FilterMatchKind.contains.rawValue

    public var isCaseSensitive: Bool = false

    /// `FilterScope`, JSON-encoded. Encoded rather than shredded into columns because it is only
    /// ever read as a whole when compiling the rule, never queried on.
    public var scopeData: Data = Data()

    public var isEnabled: Bool = true

    public var createdAt: Date = Date.now
    public var updatedAt: Date = Date.now

    public init(
        id: UUID = UUID(),
        name: String = "",
        pattern: String,
        fields: FilterFields = .titleAndContent,
        matchKind: FilterMatchKind = .contains,
        isCaseSensitive: Bool = false,
        scope: FilterScope = .everywhere,
        isEnabled: Bool = true,
        createdAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.pattern = pattern
        fieldsRaw = fields.rawValue
        matchKindRaw = matchKind.rawValue
        self.isCaseSensitive = isCaseSensitive
        scopeData = (try? JSONEncoder().encode(scope)) ?? Data()
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        updatedAt = createdAt
    }

    public var fields: FilterFields {
        get { FilterFields(rawValue: fieldsRaw) }
        set { fieldsRaw = newValue.rawValue }
    }

    public var matchKind: FilterMatchKind {
        get { FilterMatchKind(rawValue: matchKindRaw) ?? .contains }
        set { matchKindRaw = newValue.rawValue }
    }

    public var scope: FilterScope {
        get { (try? JSONDecoder().decode(FilterScope.self, from: scopeData)) ?? .everywhere }
        set { scopeData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    /// What to show in a list when the rule has no name.
    public var effectiveName: String {
        name.isEmpty ? pattern : name
    }
}
