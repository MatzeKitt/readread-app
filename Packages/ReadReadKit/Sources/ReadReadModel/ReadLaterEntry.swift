import Foundation
import ReadReadSupport
import SwiftData

/// An item marked for reading later.
///
/// **Deliberately self-contained rather than a reference to `CachedItem`.** The cache is pruned on
/// a schedule, so a foreign key would turn a months-old Read Later list into a list of dead rows.
/// Everything needed to render and open the entry is copied in at the moment it is saved, which
/// also means the list works offline and survives signing an account out.
///
/// `archivedHTML` optionally snapshots the article body so it stays readable after the source
/// deletes or paywalls it.
@Model
public final class ReadLaterEntry {

    /// The originating `CachedItem.id`. Used to reconcile with the cache and to avoid duplicates,
    /// not as a live reference.
    #Unique<ReadLaterEntry>([\.itemID])
    public var itemID: String = ""

    public var sourceID: String = ""
    public var accountID: UUID = UUID()
    public var kindRaw: String = ItemKind.article.rawValue

    public var title: String = ""
    public var sourceTitle: String = ""
    public var authorName: String?
    public var urlString: String?
    public var excerpt: String = ""
    public var iconURLString: String?

    public var publishedAt: Date = Date.distantPast

    /// `SortKey.rawValue`, so the Read Later list can carry its own reading position like any
    /// other scope.
    public var sortKeyRaw: String = ""

    /// When the user saved it. The list's default ordering — most recently saved first — because
    /// that is the order people expect from a "save for later" pile.
    public var addedAt: Date = Date.now

    /// Offline snapshot of the article body, when snapshotting is enabled.
    public var archivedHTML: String?

    /// What a search of Read Later matches against, folded. See ``SearchText``.
    ///
    /// Taken from the cached item's own ``CachedItem/searchText`` when the entry is saved on this
    /// device, so the whole body is searchable whether or not it was archived. An entry that
    /// arrived by sync has only what the snapshot carries — its archived body if there is one, its
    /// excerpt otherwise — which is all this device has ever seen of it.
    ///
    /// Local and derived: never synced, and rebuilt by ``ReadLaterService`` whenever the snapshot
    /// is. Nil means *not derived yet*, which is an entry saved before the column existed;
    /// `SearchTextBackfill` fills those in.
    public var searchText: String?

    public init(
        itemID: String,
        sourceID: String,
        accountID: UUID,
        kind: ItemKind,
        title: String,
        sourceTitle: String,
        authorName: String? = nil,
        urlString: String? = nil,
        excerpt: String = "",
        iconURLString: String? = nil,
        publishedAt: Date,
        sortKey: SortKey,
        addedAt: Date = .now,
        archivedHTML: String? = nil
    ) {
        self.itemID = itemID
        self.sourceID = sourceID
        self.accountID = accountID
        kindRaw = kind.rawValue
        self.title = title
        self.sourceTitle = sourceTitle
        self.authorName = authorName
        self.urlString = urlString
        self.excerpt = excerpt
        self.iconURLString = iconURLString
        self.publishedAt = publishedAt
        sortKeyRaw = sortKey.rawValue
        self.addedAt = addedAt
        self.archivedHTML = archivedHTML
        searchText = Self.searchText(
            title: title,
            authorName: authorName,
            excerpt: excerpt,
            archivedHTML: archivedHTML
        )
    }

    /// Snapshots a cached item into a durable Read Later entry.
    public convenience init(
        snapshotting item: CachedItem,
        sourceTitle: String,
        sourceIconURLString: String? = nil,
        archiveContent: Bool
    ) {
        self.init(
            itemID: item.id,
            sourceID: item.sourceID,
            accountID: item.accountID,
            kind: item.kind,
            title: item.title,
            sourceTitle: sourceTitle,
            authorName: item.authorName,
            urlString: item.urlString,
            excerpt: item.excerpt,
            // The feed's icon stands in where the item has none, which for an article is always:
            // see `ReadLaterService.save(_:sourceTitle:sourceIconURLString:archiveContent:in:)`.
            iconURLString: item.iconURLString ?? sourceIconURLString,
            publishedAt: item.publishedAt,
            sortKey: item.sortKey,
            archivedHTML: archiveContent ? item.contentHTML : nil
        )
        // The item's whole body, rather than what the snapshot kept of it.
        searchText = item.searchText ?? SearchText.make(for: item)
    }

    /// The searchable text for what a snapshot holds, when there is no cached item to take it from.
    static func searchText(
        title: String,
        authorName: String?,
        excerpt: String,
        archivedHTML: String?
    ) -> String {
        SearchText.make(
            title: title,
            authorName: authorName,
            body: archivedHTML.map(HTMLText.plainText(from:)) ?? excerpt
        )
    }

    public var kind: ItemKind {
        get { ItemKind(rawValue: kindRaw) ?? .article }
        set { kindRaw = newValue.rawValue }
    }

    public var sortKey: SortKey {
        get { SortKey(rawValue: sortKeyRaw) }
        set { sortKeyRaw = newValue.rawValue }
    }

    public var url: URL? {
        urlString.flatMap(URL.init(string:))
    }

    public var iconURL: URL? {
        iconURLString.flatMap(URL.init(string:))
    }
}
