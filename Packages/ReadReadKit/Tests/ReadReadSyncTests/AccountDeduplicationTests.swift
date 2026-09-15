import Foundation
import ReadReadModel
import ReadReadSupport
import SwiftData
import Testing

@testable import ReadReadSync

/// The duplicate-account failure was invisible in every existing test and obvious on a real
/// install: two copies of each account, one of which could never authenticate, and an app that
/// went minutes at a time without making a request because that copy had dragged everything into
/// the retry backoff.
@Suite("Account deduplication")
struct AccountDeduplicationTests {

    private func makeKeychain() -> KeychainStore {
        KeychainStore(
            service: "com.kittmedia.ReadRead.tests.\(UUID().uuidString)",
            prefersDataProtectionKeychain: false
        )
    }

    private func insert(
        _ id: UUID,
        server: String,
        username: String,
        createdAt: Date,
        in context: ModelContext
    ) {
        context.insert(AccountRecord(
            id: id,
            kind: .freshRSS,
            displayName: server,
            serverURLString: server,
            username: username,
            createdAt: createdAt
        ))
    }

    @Test("The copy this device cannot sign in as is removed")
    func removesTheUnusableCopy() async throws {
        let context = ModelContext(try ReadReadStore.inMemoryContainer())
        let keychain = makeKeychain()

        let mine = UUID()
        let theirs = UUID()
        // The other device's copy is *older*, so this cannot be decided by age — only the
        // credential says which one this device can use.
        insert(theirs, server: "https://rss.example.net", username: "matze", createdAt: .distantPast, in: context)
        insert(mine, server: "https://rss.example.net", username: "matze", createdAt: .now, in: context)
        try context.save()
        try await keychain.setString("p", for: .freshRSSAPIPassword, key: mine.uuidString)

        let removed = try AccountDeduplication.removeUnusableDuplicates(keychain: keychain, in: context)

        #expect(removed.count == 1)
        let survivors = try context.fetch(FetchDescriptor<AccountRecord>())
        #expect(survivors.map(\.id) == [mine])
    }

    @Test("Removal is local, so the other device keeps its account")
    func doesNotPushADeletion() async throws {
        let context = ModelContext(try ReadReadStore.inMemoryContainer())
        let keychain = makeKeychain()
        let mine = UUID()
        insert(mine, server: "https://rss.example.net", username: "matze", createdAt: .now, in: context)
        insert(UUID(), server: "https://rss.example.net", username: "matze", createdAt: .now, in: context)
        try context.save()
        try await keychain.setString("p", for: .freshRSSAPIPassword, key: mine.uuidString)

        try AccountDeduplication.removeUnusableDuplicates(keychain: keychain, in: context)

        // A pushed tombstone would delete the *working* account on the device that owns it, taking
        // its feeds and reading positions with it. Nothing may be queued.
        #expect(try context.fetchCount(FetchDescriptor<PendingChange>()) == 0)
    }

    @Test("Addresses that differ only cosmetically are the same account")
    func normalisesTheServerAddress() async throws {
        let context = ModelContext(try ReadReadStore.inMemoryContainer())
        let keychain = makeKeychain()
        let mine = UUID()
        insert(mine, server: "https://rss.example.net/", username: "Matze", createdAt: .now, in: context)
        insert(UUID(), server: "rss.example.NET", username: "matze", createdAt: .now, in: context)
        try context.save()
        try await keychain.setString("p", for: .freshRSSAPIPassword, key: mine.uuidString)

        try AccountDeduplication.removeUnusableDuplicates(keychain: keychain, in: context)

        #expect(try context.fetch(FetchDescriptor<AccountRecord>()).map(\.id) == [mine])
    }

    @Test("Two genuinely different accounts on one host are both kept")
    func keepsDistinctAccounts() async throws {
        let context = ModelContext(try ReadReadStore.inMemoryContainer())
        let keychain = makeKeychain()
        insert(UUID(), server: "https://rss.example.net", username: "matze", createdAt: .now, in: context)
        insert(UUID(), server: "https://rss.example.net", username: "someone-else", createdAt: .now, in: context)
        try context.save()

        let removed = try AccountDeduplication.removeUnusableDuplicates(keychain: keychain, in: context)

        #expect(removed.isEmpty)
        #expect(try context.fetchCount(FetchDescriptor<AccountRecord>()) == 2)
    }

    @Test("With no credential for either copy, one is kept rather than both discarded")
    func keepsOneWhenNeitherIsUsable() throws {
        let context = ModelContext(try ReadReadStore.inMemoryContainer())
        let keychain = makeKeychain()
        let older = UUID()
        insert(older, server: "https://rss.example.net", username: "matze", createdAt: .distantPast, in: context)
        insert(UUID(), server: "https://rss.example.net", username: "matze", createdAt: .now, in: context)
        try context.save()

        try AccountDeduplication.removeUnusableDuplicates(keychain: keychain, in: context)

        // Signing in has to remain possible, so the account cannot be deleted just because no
        // password is stored yet — which is the state every newly synced account starts in.
        #expect(try context.fetch(FetchDescriptor<AccountRecord>()).map(\.id) == [older])
    }
}
