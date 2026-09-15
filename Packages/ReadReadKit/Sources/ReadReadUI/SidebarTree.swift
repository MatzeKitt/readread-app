import Foundation
import ReadReadModel
import SwiftData

/// A row in the sidebar.
///
/// A value type derived from the store rather than a view built directly from `@Query` results:
/// the sidebar mixes fixed entries, per-account groups, folders and feeds, and expressing that as
/// one flat list of typed rows keeps the view free of nested conditionals — and makes the tree
/// itself testable without rendering anything.
public struct SidebarRow: Identifiable, Hashable, Sendable {

    public enum Kind: Hashable, Sendable {
        case allItems
        case readLater
        case lateArrivals
        case filtered
        case folder(name: String)
        case feed(sourceID: String)
        case mastodonHome(accountID: UUID)
    }

    public var kind: Kind
    public var title: String
    public var iconURLString: String?

    /// SF Symbol used when there is no favicon, or as the icon for fixed entries.
    public var systemImage: String

    /// Children, for a folder row. Empty for every other kind.
    public var children: [SidebarRow]

    public var id: String { scope.rawValue }

    /// The scope whose threshold and count this row displays.
    public var scope: ScopeID {
        switch kind {
        case .allItems: .all
        case .readLater: .readLater
        case .lateArrivals: .lateArrivals
        case .filtered: .filtered
        case .folder(let name): .folder(name)
        case .feed(let sourceID): .source(sourceID)
        case .mastodonHome(let accountID): .mastodonHome(accountID: accountID)
        }
    }

    public init(
        kind: Kind,
        title: String,
        iconURLString: String? = nil,
        systemImage: String,
        children: [SidebarRow] = []
    ) {
        self.kind = kind
        self.title = title
        self.iconURLString = iconURLString
        self.systemImage = systemImage
        self.children = children
    }

    /// This row and every descendant, for aggregate work like refreshing counts.
    public var selfAndDescendants: [SidebarRow] {
        [self] + children.flatMap(\.selfAndDescendants)
    }
}

/// One titled section of the sidebar.
public struct SidebarSection: Identifiable, Hashable, Sendable {

    /// `nil` for the unlabelled first section, which holds All Items and Read Later.
    public var title: String?
    public var rows: [SidebarRow]

    public var id: String { title ?? "" }

    public init(title: String?, rows: [SidebarRow]) {
        self.title = title
        self.rows = rows
    }
}

/// Builds the sidebar's sections from the store.
public enum SidebarTree {

    public static func build(accounts: [AccountRecord], sources: [CachedSource]) -> [SidebarSection] {
        var sections: [SidebarSection] = [
            SidebarSection(title: nil, rows: [
                SidebarRow(kind: .allItems, title: String(localized: "All Items"), systemImage: "tray.full"),
                SidebarRow(kind: .readLater, title: String(localized: "Read Later"), systemImage: "bookmark"),
                // Always present, like the other smart lists. A row that appeared only when
                // something was waiting would be missing exactly when a user went looking for the
                // thing they had just been told about.
                SidebarRow(kind: .lateArrivals, title: String(localized: "Older Items"), systemImage: "clock.arrow.circlepath"),
                // Here rather than behind the filter settings, which is where it used to be. The
                // question it answers — "where did that item go?" — is asked while looking at the
                // timeline, and a list you can only reach by first suspecting your own filter
                // rules is no use to someone who does not yet suspect them.
                //
                // Always present, like the other smart lists, and for the same reason: a row that
                // appeared only when something was hidden would be missing exactly when someone
                // went looking for what had gone. It carries no count unless asked to — see
                // `ReadingSettings.showsFilteredItemsBadge`.
                SidebarRow(kind: .filtered, title: String(localized: "Filtered Items"), systemImage: "eye.slash"),
            ]),
        ]

        let enabledAccounts = accounts.filter(\.isEnabled).sorted { $0.createdAt < $1.createdAt }

        for account in enabledAccounts {
            let accountSources = sources
                .filter { $0.accountID == account.id && $0.isSubscribed }
                .sorted { ($0.sortIndex, $0.title) < ($1.sortIndex, $1.title) }

            guard !accountSources.isEmpty else { continue }

            let rows = switch account.kind {
            case .freshRSS: groupedByFolder(accountSources)
            case .mastodon: mastodonRows(for: account, sources: accountSources)
            }

            sections.append(SidebarSection(title: account.displayName, rows: rows))
        }

        return sections
    }

    /// Groups feeds under their FreshRSS category, with uncategorised feeds promoted to the top
    /// level rather than hidden inside a synthetic "Uncategorised" folder that would have its own
    /// threshold and count.
    private static func groupedByFolder(_ sources: [CachedSource]) -> [SidebarRow] {
        var folderNames: [String] = []
        var byFolder: [String: [CachedSource]] = [:]
        var ungrouped: [CachedSource] = []

        for source in sources {
            guard let folder = source.folderName, !folder.isEmpty else {
                ungrouped.append(source)
                continue
            }
            if byFolder[folder] == nil {
                folderNames.append(folder)
                byFolder[folder] = []
            }
            byFolder[folder]?.append(source)
        }

        let folderRows = folderNames.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { name in
                SidebarRow(
                    kind: .folder(name: name),
                    title: name,
                    systemImage: "folder",
                    children: (byFolder[name] ?? []).map(feedRow)
                )
            }

        return folderRows + ungrouped.map(feedRow)
    }

    private static func feedRow(for source: CachedSource) -> SidebarRow {
        SidebarRow(
            kind: .feed(sourceID: source.id),
            title: source.title,
            iconURLString: source.iconURLString,
            systemImage: "dot.radiowaves.up.forward"
        )
    }

    private static func mastodonRows(for account: AccountRecord, sources: [CachedSource]) -> [SidebarRow] {
        // Only the home timeline in v1, so the account's single row is addressed by the dedicated
        // `mastodonHome` scope rather than by its source id.
        sources.map { source in
            SidebarRow(
                kind: .mastodonHome(accountID: account.id),
                title: source.title,
                iconURLString: source.iconURLString,
                systemImage: "bubble.left.and.bubble.right"
            )
        }
    }
}
