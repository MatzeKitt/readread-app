import Foundation
import ReadReadModel
import SwiftData

/// The store's shape before this round of changes.
///
/// ## Not used at runtime
///
/// Building a `ModelContainer` from this **crashes the test process**, intermittently, and the
/// reason is worth stating because it is not obvious: SwiftData names an entity after its class,
/// so these are `CachedItem` and `CachedSource` on disk — the same names the live models use. Two
/// containers alive at once with two different definitions of one entity name leaves CoreData
/// resolving the name to whichever registered first, and the other one's code then sets a key the
/// winner does not have:
///
/// ```
/// 'NSUnknownKeyException': the entity CachedSource is not key value coding-compliant
/// for the key "loadsFullPageContent"
/// ```
///
/// Tests run in parallel, so "at once" happens whenever any other suite touches the store. The
/// migration test therefore reads a **pre-generated fixture** — `Fixtures/legacy-v1.store` — and
/// only ever opens it with the live schema. These declarations remain as the record of what that
/// file contains, and as the thing to edit and re-run if it ever needs regenerating.
///
/// SwiftData names an entity after the class, and a nested class keeps that name — so these are
/// `CachedItem`, `CachedSource` and friends on disk, exactly as an older build wrote them, while
/// staying distinct Swift types from the live models.
///
/// Deliberately hand-written rather than derived from the live models: the point is to have a *fixed* record of what
/// the old store looked like, which the live models can then drift away from. Regenerating it from
/// the current models would make it agree with them by construction and prove nothing.
enum LegacySchema {

    static let schema = Schema([
        LegacySchema.CachedItem.self,
        LegacySchema.CachedSource.self,
        LegacySchema.PositionMark.self,
        LegacySchema.ReadLaterEntry.self,
        LegacySchema.FilterRule.self,
        LegacySchema.AccountRecord.self,
    ])

    /// Missing, relative to the live model: `replyCount`, `reblogCount`, `favouriteCount`,
    /// `inReplyToStatusID`, `fullPageHTML` and `fullPageFetchedAt`.
    @Model
    final class CachedItem {
        #Unique<CachedItem>([\.id])
        #Index<CachedItem>([\.sortKeyRaw], [\.sourceID, \.sortKeyRaw], [\.folderName, \.sortKeyRaw], [\.ingestKeyRaw])

        var id: String = ""
        var sourceID: String = ""
        var accountID: UUID = UUID()
        var folderName: String?
        var kindRaw: String = "article"
        var title: String = ""
        var authorName: String?
        var urlString: String?
        var contentHTML: String = ""
        var excerpt: String = ""
        var publishedAt: Date = Date.distantPast
        var sortKeyRaw: String = ""
        var ingestKeyRaw: String = ""
        var arrivedLate: Bool = false
        var iconURLString: String?
        var isFilteredOut: Bool = false
        // Shared with the live model: the value type is not what is being migrated here.
        var attachments: [ReadReadModel.Attachment] = []
        var mastodonPayload: Data?

        init(id: String, sourceID: String, accountID: UUID, title: String, sortKeyRaw: String, ingestKeyRaw: String) {
            self.id = id
            self.sourceID = sourceID
            self.accountID = accountID
            self.title = title
            self.sortKeyRaw = sortKeyRaw
            self.ingestKeyRaw = ingestKeyRaw
        }
    }

    /// Missing, relative to the live model: `loadsFullPageContent`.
    @Model
    final class CachedSource {
        #Unique<CachedSource>([\.id])

        var id: String = ""
        var accountID: UUID = UUID()
        var kindRaw: String = "article"
        var title: String = ""
        var homepageURLString: String?
        var iconURLString: String?
        var folderName: String?
        var sortIndex: Int = 0
        var isSubscribed: Bool = true

        init(id: String, accountID: UUID, title: String, folderName: String? = nil) {
            self.id = id
            self.accountID = accountID
            self.title = title
            self.folderName = folderName
        }
    }

    @Model
    final class PositionMark {
        #Unique<PositionMark>([\.key])

        var key: String = ""
        var scopeRaw: String = "all"
        var deviceID: String = ""
        var markSortKeyRaw: String = ""
        var updatedAt: Date = Date.now

        init(key: String, scopeRaw: String, deviceID: String, markSortKeyRaw: String) {
            self.key = key
            self.scopeRaw = scopeRaw
            self.deviceID = deviceID
            self.markSortKeyRaw = markSortKeyRaw
        }
    }

    @Model
    final class ReadLaterEntry {
        #Unique<ReadLaterEntry>([\.itemID])

        var itemID: String = ""
        var sourceID: String = ""
        var accountID: UUID = UUID()
        var kindRaw: String = "article"
        var title: String = ""
        var sourceTitle: String = ""
        var authorName: String?
        var urlString: String?
        var excerpt: String = ""
        var iconURLString: String?
        var publishedAt: Date = Date.distantPast
        var sortKeyRaw: String = ""
        var addedAt: Date = Date.now
        var archivedHTML: String?

        init(itemID: String, sourceID: String, accountID: UUID, title: String, archivedHTML: String?) {
            self.itemID = itemID
            self.sourceID = sourceID
            self.accountID = accountID
            self.title = title
            self.archivedHTML = archivedHTML
        }
    }

    @Model
    final class FilterRule {
        #Unique<FilterRule>([\.id])

        var id: UUID = UUID()
        var name: String = ""
        var pattern: String = ""
        var fieldsRaw: Int = 0
        var matchKindRaw: String = "contains"
        var isCaseSensitive: Bool = false
        var scopeData: Data = Data()
        var isEnabled: Bool = true
        var createdAt: Date = Date.now
        var updatedAt: Date = Date.now

        init(id: UUID, name: String, pattern: String, fieldsRaw: Int, scopeData: Data) {
            self.id = id
            self.name = name
            self.pattern = pattern
            self.fieldsRaw = fieldsRaw
            self.scopeData = scopeData
        }
    }

    @Model
    final class AccountRecord {
        #Unique<AccountRecord>([\.id])

        var id: UUID = UUID()
        var kindRaw: String = "freshRSS"
        var displayName: String = ""
        var serverURLString: String = ""
        var username: String = ""
        var createdAt: Date = Date.now
        var isEnabled: Bool = true

        init(id: UUID, kindRaw: String, displayName: String, serverURLString: String, username: String) {
            self.id = id
            self.kindRaw = kindRaw
            self.displayName = displayName
            self.serverURLString = serverURLString
            self.username = username
        }
    }
}
