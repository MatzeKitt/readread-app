import Foundation
import Testing
@testable import FreshRSSAPI

/// The subscription list is what the entire sidebar is built from, so a server that omits a field
/// must cost at most that field — never the list.
@Suite("Subscription decoding tolerance")
struct SubscriptionToleranceTests {

    private func decode(_ json: String) throws -> [GReaderSubscription] {
        try JSONDecoder()
            .decode(GReaderSubscriptionList.self, from: Data(json.utf8))
            .subscriptions
    }

    @Test("A subscription with no categories still decodes, alongside its neighbours")
    func missingCategories() throws {
        let subscriptions = try decode("""
        {"subscriptions":[
          {"id":"feed/1","title":"No categories key"},
          {"id":"feed/2","title":"Filed","categories":[{"id":"user/-/label/Tech","label":"Tech"}]}
        ]}
        """)

        #expect(subscriptions.count == 2)
        #expect(subscriptions[0].folderName == nil)
        #expect(subscriptions[1].folderName == "Tech")
    }

    @Test("An untitled feed falls back to its id rather than a blank row")
    func missingTitle() throws {
        let subscriptions = try decode(#"{"subscriptions":[{"id":"feed/7","categories":[]}]}"#)
        #expect(subscriptions.first?.title == "feed/7")
    }

    @Test("A body with no subscriptions key is an empty list, not a failure")
    func missingKey() throws {
        #expect(try decode("{}").isEmpty)
    }

    @Test("A category with only an id is named from the id")
    func categoryWithoutLabel() throws {
        let subscriptions = try decode(#"""
        {"subscriptions":[{"id":"feed/1","title":"T","categories":[{"id":"user/-/label/News/EU"}]}]}
        """#)
        #expect(subscriptions.first?.folderName == "News/EU")
    }

    @Test("A subscription with no id is still a failure, because it cannot be stored")
    func missingID() {
        #expect(throws: (any Error).self) {
            try decode(#"{"subscriptions":[{"title":"Nameless"}]}"#)
        }
    }
}

/// Pinned against a payload captured from a **running** FreshRSS, not one written by hand.
///
/// The bug these exist for was invisible to every other test in this package: `frss:priority` was
/// modelled as `Int` from FreshRSS's integer priority constants, the hand-written fixture was
/// written to agree with that model, and a live server sends `"main"`. Both the code and its
/// evidence were wrong in the same direction, so the suite was green while the app could not list
/// a single feed.
///
/// A fixture is only evidence if it came from the thing it claims to describe.
@Suite("Live subscription payload")
struct LiveSubscriptionPayloadTests {

    private func liveSubscriptions() throws -> [GReaderSubscription] {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/subscription-list-live", withExtension: "json"))
        return try JSONDecoder()
            .decode(GReaderSubscriptionList.self, from: try Data(contentsOf: url))
            .subscriptions
    }

    @Test("A priority sent as a name decodes, and the whole list survives it")
    func priorityIsAName() throws {
        let subscriptions = try liveSubscriptions()

        #expect(subscriptions.count == 3)
        #expect(subscriptions.allSatisfy { $0.frssPriority == "main" })
    }

    @Test("Feeds, folders and icons come through as the sidebar needs them")
    func sidebarFields() throws {
        let subscriptions = try liveSubscriptions()

        #expect(subscriptions.map(\.feedID) == ["16", "24", "104"])
        #expect(subscriptions.map(\.folderName) == ["RSS", "RSS", "Updates"])
        #expect(subscriptions.allSatisfy { $0.iconURLString != nil })
        #expect(subscriptions[2].title.contains("WoltLab®"))
    }

    @Test("A priority sent as a number still decodes, so older servers keep working")
    func priorityAsNumber() throws {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/subscription-list", withExtension: "json"))
        let subscriptions = try JSONDecoder()
            .decode(GReaderSubscriptionList.self, from: try Data(contentsOf: url))
            .subscriptions

        #expect(subscriptions.last?.frssPriority == "0")
    }
}
