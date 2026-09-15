import Foundation
import ReadReadModel
import ReadReadSupport
import SwiftData
import Testing

@testable import ReadReadSync

/// Drives the real Swift client against the real PHP service over real HTTP.
///
/// The stubbed tests pin down merge policy and paging logic; they cannot catch a disagreement
/// between the two halves — a field named differently on each side, a header the server does not
/// read, a status code the client misreads. Those only show up when both are running.
///
/// Skipped automatically when PHP is unavailable, so the suite stays green on a machine without it.
@Suite("Sync end-to-end", .serialized)
struct SyncEndToEndTests {

    // MARK: - Harness

    /// A `php -S` instance with its own throwaway database and a freshly minted token.
    private final class Server {

        let baseURL: URL
        let token: String
        private let process: Process
        private let databasePath: String

        init() throws {
            let root = Self.serverRoot
            databasePath = FileManager.default.temporaryDirectory
                .appendingPathComponent("readread-sync-e2e-\(UUID().uuidString).sqlite").path

            // Mint a token through the real CLI, so the token format and hashing are exercised too.
            let cli = Process()
            cli.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            cli.arguments = ["php", "\(root)/bin/readread-sync", "token:create", "--label=e2e"]
            cli.environment = ["READREAD_SYNC_DB": databasePath, "PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"]
            let pipe = Pipe()
            cli.standardOutput = pipe
            cli.standardError = Pipe()
            try cli.run()
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            cli.waitUntilExit()

            guard let token = output
                .split(separator: "\n")
                .map({ $0.trimmingCharacters(in: .whitespaces) })
                .first(where: { !$0.isEmpty && !$0.contains(" ") && $0.count > 30 })
            else {
                throw HarnessError.tokenUnavailable(output)
            }
            self.token = token

            // Port 0 is not usable with `php -S`, so pick a high port and let a clash surface as a
            // startup failure rather than a mysterious hang.
            let port = Int.random(in: 42_000...59_000)
            baseURL = URL(string: "http://127.0.0.1:\(port)")!

            process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [
                "php", "-S", "127.0.0.1:\(port)", "-t", "\(root)/public", "\(root)/public/index.php",
            ]
            process.environment = ["READREAD_SYNC_DB": databasePath, "PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try process.run()
        }

        /// Polls health until the server answers.
        func waitUntilReady() async throws {
            let url = baseURL.appendingPathComponent("api/v1/health")
            for _ in 0..<80 {
                if let (_, response) = try? await URLSession.shared.data(from: url),
                   (response as? HTTPURLResponse)?.statusCode == 200 {
                    return
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw HarnessError.serverDidNotStart
        }

        func shutDown() {
            process.terminate()
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: databasePath + suffix)
            }
        }

        /// Locates `server/` relative to this source file, so the test does not depend on the
        /// working directory the test runner happens to use.
        static var serverRoot: String {
            URL(fileURLWithPath: #filePath)          // .../Tests/ReadReadSyncTests/ThisFile.swift
                .deletingLastPathComponent()          // .../Tests/ReadReadSyncTests
                .deletingLastPathComponent()          // .../Tests
                .deletingLastPathComponent()          // .../ReadReadKit
                .deletingLastPathComponent()          // .../Packages
                .deletingLastPathComponent()          // repo root
                .appendingPathComponent("server")
                .path
        }

        static var isAvailable: Bool {
            FileManager.default.fileExists(atPath: "\(serverRoot)/public/index.php")
                && (try? Process.run(URL(fileURLWithPath: "/usr/bin/env"), arguments: ["which", "php"])) != nil
        }

        enum HarnessError: Error {
            case serverDidNotStart
            case tokenUnavailable(String)
        }
    }

    private func withServer<T>(_ body: (Server) async throws -> T) async throws -> T {
        try #require(Server.isAvailable, "PHP or the server directory is unavailable")
        let server = try Server()
        defer { server.shutDown() }
        try await server.waitUntilReady()
        return try await body(server)
    }

    private func makeDevice(_ server: Server) throws -> (SyncCoordinator, SyncStore, ModelContainer) {
        let container = try ReadReadStore.inMemoryContainer()
        let store = SyncStore(modelContainer: container)
        let client = SyncClient(
            configuration: SyncConfiguration(baseURL: server.baseURL, token: server.token),
            // A real socket, so no stub transport and no fake clock.
            http: HTTPClient(policy: RetryPolicy(maxAttempts: 2))
        )
        return (SyncCoordinator(client: client, store: store), store, container)
    }

    private func positionPayload(
        device: String,
        millis: Int64,
        writtenAt: TimeInterval = 0
    ) throws -> String {
        try SyncPayloadCoding.encodeToString(PositionPayload(
            scope: "all",
            deviceID: device,
            markSortKey: SortKey(millis: millis, id: "i").rawValue,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000 + writtenAt)
        ))
    }

    // MARK: - Tests

    @Test("The service reports itself healthy")
    func healthCheck() async throws {
        try await withServer { server in
            let client = SyncClient(configuration: .init(baseURL: server.baseURL, token: server.token))

            let health = try await client.health()

            #expect(health.ok)
            #expect(health.service == "readread-sync")
        }
    }

    @Test("A token minted by the CLI is accepted, and a wrong one is not")
    func realTokenIsAccepted() async throws {
        try await withServer { server in
            let good = SyncClient(configuration: .init(baseURL: server.baseURL, token: server.token))
            _ = try await good.pull(since: 0)

            let bad = SyncClient(configuration: .init(baseURL: server.baseURL, token: "not-the-token"))
            await #expect(throws: SyncError.unauthorized) {
                _ = try await bad.pull(since: 0)
            }
        }
    }

    /// The whole point of the feature, exercised for real: a position set on one device turns up
    /// on another through the user's own server.
    @Test("A reading position set on one device reaches another")
    func positionCrossesDevices() async throws {
        try await withServer { server in
            let (macCoordinator, macStore, macContainer) = try makeDevice(server)
            let (phoneCoordinator, _, phoneContainer) = try makeDevice(server)

            // The Mac reads to a position and queues it.
            let macContext = ModelContext(macContainer)
            try ThresholdService.setPosition(
                .all,
                to: SortKey(millis: 7_000, id: "i"),
                deviceID: "mac",
                in: macContext
            )
            try macContext.save()
            try await macStore.enqueue(
                collection: .position,
                recordID: "all|mac",
                payload: try positionPayload(device: "mac", millis: 7_000)
            )

            let pushOutcome = try await macCoordinator.sync()
            #expect(pushOutcome.pushedRecords == 1)

            // The phone syncs and learns about it.
            let pullOutcome = try await phoneCoordinator.sync()
            #expect(pullOutcome.appliedRecords == 1)

            let marks = try ModelContext(phoneContainer).fetch(FetchDescriptor<PositionMark>())
            #expect(marks.count == 1)
            #expect(marks[0].deviceID == "mac")
            #expect(marks[0].markSortKey.millis == 7_000)

            // And the effective position on the phone is the Mac's.
            let position = try ThresholdService.effectivePosition(for: .all, in: ModelContext(phoneContainer))
            #expect(position.markSortKey.millis == 7_000)
        }
    }

    /// Per-device rows are what make positions conflict-free. Two devices writing at once must
    /// both survive, with the furthest winning the reduction.
    @Test("Two devices' positions coexist and the furthest wins")
    func twoDevicesCoexist() async throws {
        try await withServer { server in
            let (macCoordinator, macStore, _) = try makeDevice(server)
            let (phoneCoordinator, phoneStore, _) = try makeDevice(server)
            let (thirdCoordinator, _, thirdContainer) = try makeDevice(server)

            try await macStore.enqueue(
                collection: .position,
                recordID: "all|mac",
                payload: try positionPayload(device: "mac", millis: 3_000)
            )
            try await phoneStore.enqueue(
                collection: .position,
                recordID: "all|phone",
                payload: try positionPayload(device: "phone", millis: 8_000)
            )

            _ = try await macCoordinator.sync()
            _ = try await phoneCoordinator.sync()
            _ = try await thirdCoordinator.sync()

            let context = ModelContext(thirdContainer)
            #expect(try context.fetchCount(FetchDescriptor<PositionMark>()) == 2)
            // Reduction takes the further of the two, so nothing already read resurfaces.
            #expect(try ThresholdService.effectivePosition(for: .all, in: context).markSortKey.millis == 8_000)
        }
    }

    @Test("A read-later entry and its deletion both propagate")
    func readLaterPropagatesIncludingDeletion() async throws {
        try await withServer { server in
            let (aCoordinator, aStore, _) = try makeDevice(server)
            let (bCoordinator, _, bContainer) = try makeDevice(server)

            let entry = ReadLaterEntry(
                itemID: "item-1",
                sourceID: "feed-1",
                accountID: UUID(),
                kind: .article,
                title: "Saved for later",
                sourceTitle: "Feed One",
                publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
                sortKey: SortKey(millis: 1_700_000_000_000, id: "item-1")
            )
            try await aStore.enqueue(
                collection: .readLater,
                recordID: entry.itemID,
                payload: try SyncPayloadCoding.encodeToString(ReadLaterPayload(entry))
            )
            _ = try await aCoordinator.sync()
            _ = try await bCoordinator.sync()

            var entries = try ModelContext(bContainer).fetch(FetchDescriptor<ReadLaterEntry>())
            #expect(entries.count == 1)
            #expect(entries[0].title == "Saved for later")

            // A deletion must be delivered, not merely absent, or the other device would keep it
            // forever and re-upload it.
            try await aStore.enqueueDeletion(collection: .readLater, recordID: "item-1")
            _ = try await aCoordinator.sync()
            _ = try await bCoordinator.sync()

            entries = try ModelContext(bContainer).fetch(FetchDescriptor<ReadLaterEntry>())
            #expect(entries.isEmpty)
        }
    }

    /// A device that has been away needs to catch up across several pages, and the cursor has to
    /// walk forward correctly against a real server rather than a scripted one.
    @Test("A device catches up across multiple real pages")
    func catchesUpAcrossPages() async throws {
        try await withServer { server in
            let (writerCoordinator, writerStore, _) = try makeDevice(server)

            for index in 0..<25 {
                try await writerStore.enqueue(
                    collection: .position,
                    recordID: "all|device-\(index)",
                    payload: try positionPayload(device: "device-\(index)", millis: Int64(index + 1) * 100)
                )
            }
            let pushed = try await writerCoordinator.sync()
            #expect(pushed.pushedRecords == 25)

            // A fresh device pulls with a deliberately tiny page size.
            let container = try ReadReadStore.inMemoryContainer()
            let store = SyncStore(modelContainer: container)
            let client = SyncClient(
                configuration: .init(baseURL: server.baseURL, token: server.token),
                http: HTTPClient(policy: RetryPolicy(maxAttempts: 2))
            )

            var cursor = 0
            var pages = 0
            var applied = 0
            while pages < 20 {
                let page = try await client.pull(since: cursor, limit: 10)
                pages += 1
                applied += try await store.apply(page)
                cursor = try await store.pullCursor()
                if !page.hasMore { break }
            }

            #expect(pages == 3)
            #expect(applied == 25)
            #expect(try ModelContext(container).fetchCount(FetchDescriptor<PositionMark>()) == 25)
            #expect(cursor == 25)
        }
    }

    /// The rule that only a pull may advance the pull cursor, verified against a real server where
    /// the push response genuinely reports a higher revision than this device has pulled.
    @Test("A push does not let this device skip another device's changes")
    func pushDoesNotSkipRemoteChanges() async throws {
        try await withServer { server in
            let (otherCoordinator, otherStore, _) = try makeDevice(server)
            let (myCoordinator, myStore, myContainer) = try makeDevice(server)

            // Another device writes first, and this device has not pulled it.
            try await otherStore.enqueue(
                collection: .position,
                recordID: "all|other",
                payload: try positionPayload(device: "other", millis: 4_000)
            )
            _ = try await otherCoordinator.sync()

            // This device queues its own change, then syncs. The push response will report a
            // revision above the one it is about to learn from the pull.
            try await myStore.enqueue(
                collection: .position,
                recordID: "all|mine",
                payload: try positionPayload(device: "mine", millis: 1_000)
            )
            _ = try await myCoordinator.sync()

            // A second sync must still deliver its own record back, and the other device's must
            // already be present rather than having been skipped.
            _ = try await myCoordinator.sync()

            let devices = try ModelContext(myContainer)
                .fetch(FetchDescriptor<PositionMark>())
                .map(\.deviceID)
                .sorted()
            #expect(devices == ["mine", "other"])
        }
    }

    @Test("The server's record caps are reported as rejections the client can act on")
    func serverCapsSurfaceAsRejections() async throws {
        try await withServer { server in
            let client = SyncClient(
                configuration: .init(baseURL: server.baseURL, token: server.token),
                http: HTTPClient(policy: RetryPolicy(maxAttempts: 1))
            )

            let tooMany = (0...600).map {
                SyncPushRecord(collection: .filter, id: "bulk-\($0)", payload: "{}")
            }
            do {
                _ = try await client.push(tooMany)
                Issue.record("expected a rejection")
            } catch let error as SyncError {
                guard case .rejected = error else {
                    Issue.record("expected .rejected, got \(error)")
                    return
                }
            }

            // A rejected batch must store nothing, or the client would believe records landed.
            let page = try await client.pull(since: 0)
            #expect(page.records.isEmpty)
        }
    }
}
