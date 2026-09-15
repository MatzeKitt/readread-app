import Foundation
import SwiftUI
import Testing

@testable import ReadReadUI

/// Paging through a post's pictures with the arrow keys sometimes left one saying "This image
/// could not be loaded", while opening the viewer on that same picture worked perfectly. That is a
/// cancelled load being reported as a failed one: `AsyncImage`'s load belongs to its view, a lazy
/// stack takes the view down when the page scrolls out, and SwiftUI then restores the page's state
/// with the cancellation latched — and `AsyncImage` will not retry, because from its side nothing
/// changed. These cover the loader that replaced it.
@MainActor
@Suite("Media image loading")
struct MediaImageLoaderTests {

    private let url = URL(string: "https://files.example/photo.jpg")!
    private let other = URL(string: "https://files.example/second.jpg")!

    /// Hands out results on demand, so a test can hold a load open and ask what the loader is
    /// saying while it is still in flight.
    private final class Fetcher: @unchecked Sendable {

        private let lock = NSLock()
        private var pending: [URL: CheckedContinuation<Image?, Never>] = [:]
        private var calls: [URL] = []

        var callCount: Int { lock.withLock { calls.count } }

        func callCount(for url: URL) -> Int {
            lock.withLock { calls.filter { $0 == url }.count }
        }

        func fetch(_ url: URL) async -> Image? {
            lock.withLock { calls.append(url) }
            return await withCheckedContinuation { continuation in
                lock.withLock { pending[url] = continuation }
            }
        }

        /// Waits for the load to arrive, then answers it.
        func complete(_ url: URL, with image: Image?) async {
            for _ in 0..<200 {
                let continuation = lock.withLock { pending.removeValue(forKey: url) }
                if let continuation {
                    continuation.resume(returning: image)
                    // Let the loader's task run to its `finish`.
                    await Task.yield()
                    try? await Task.sleep(for: .milliseconds(10))
                    return
                }
                try? await Task.sleep(for: .milliseconds(5))
            }
            Issue.record("No load was started for \(url)")
        }
    }

    private func makeLoader() -> (MediaImageLoader, Fetcher) {
        let fetcher = Fetcher()
        return (MediaImageLoader(fetch: { await fetcher.fetch($0) }), fetcher)
    }

    /// Polls until it holds. The loader records a fetch from inside its detached task, so a
    /// synchronous assertion on the call count races that task rather than testing anything.
    private func eventually(_ condition: @escaping () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    /// Gives a load that *should not* start the chance to have started, so asserting it did not is
    /// worth something.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(50))
    }

    private func isLoading(_ state: MediaImageLoader.State) -> Bool {
        if case .loading = state { return true }
        return false
    }

    private func isLoaded(_ state: MediaImageLoader.State) -> Bool {
        if case .loaded = state { return true }
        return false
    }

    private func isFailed(_ state: MediaImageLoader.State) -> Bool {
        if case .failed = state { return true }
        return false
    }

    @Test("Asking about a picture starts fetching it")
    func firstAskStartsTheLoad() async {
        let (loader, fetcher) = makeLoader()

        #expect(isLoading(loader.state(for: url)))
        await fetcher.complete(url, with: Image(systemName: "photo"))
        #expect(isLoaded(loader.state(for: url)))
    }

    /// The whole point of the change. A page that scrolls out and back must find the picture
    /// already there — the load is not owned by the view, so nothing about the view's lifetime can
    /// undo it.
    @Test("A loaded picture is remembered, and not fetched twice")
    func loadedPicturesAreRemembered() async {
        let (loader, fetcher) = makeLoader()

        _ = loader.state(for: url)
        await fetcher.complete(url, with: Image(systemName: "photo"))

        // Paging away and back: many more asks, no more loads.
        for _ in 0..<5 { #expect(isLoaded(loader.state(for: url))) }
        #expect(fetcher.callCount(for: url) == 1)
    }

    /// Two pages showing the same picture — the same image attached twice — must not both download
    /// it, and neither must a re-render while the first load is still open.
    @Test("Asking repeatedly mid-flight starts one load, not several")
    func inFlightLoadsAreNotDuplicated() async {
        let (loader, fetcher) = makeLoader()

        for _ in 0..<4 { #expect(isLoading(loader.state(for: url))) }
        #expect(await eventually { fetcher.callCount(for: url) == 1 })
        await settle()
        #expect(fetcher.callCount(for: url) == 1)

        await fetcher.complete(url, with: Image(systemName: "photo"))
        #expect(isLoaded(loader.state(for: url)))
    }

    @Test("Nothing usable at the far end is a failure, and it is remembered")
    func failureIsRecorded() async {
        let (loader, fetcher) = makeLoader()

        _ = loader.state(for: url)
        await fetcher.complete(url, with: nil)

        #expect(isFailed(loader.state(for: url)))
        // Not retried on its own: a failure that re-fetches on every redraw is a hot loop against
        // a server that has already said no.
        #expect(fetcher.callCount(for: url) == 1)
    }

    @Test("Trying again asks again")
    func retryRefetches() async {
        let (loader, fetcher) = makeLoader()

        _ = loader.state(for: url)
        await fetcher.complete(url, with: nil)
        #expect(isFailed(loader.state(for: url)))

        loader.retry(url)
        #expect(isLoading(loader.state(for: url)))
        #expect(await eventually { fetcher.callCount(for: url) == 2 })

        await fetcher.complete(url, with: Image(systemName: "photo"))
        #expect(isLoaded(loader.state(for: url)))
    }

    /// Otherwise a stray retry on a picture that is fine would throw it away and reload it.
    @Test("Trying again does nothing to a picture that is not broken")
    func retryIgnoresHealthyPictures() async {
        let (loader, fetcher) = makeLoader()

        _ = loader.state(for: url)
        await fetcher.complete(url, with: Image(systemName: "photo"))

        loader.retry(url)
        #expect(isLoaded(loader.state(for: url)))
        await settle()
        #expect(fetcher.callCount(for: url) == 1)

        // And one still in flight is left alone too.
        _ = loader.state(for: other)
        loader.retry(other)
        #expect(isLoading(loader.state(for: other)))
        #expect(await eventually { fetcher.callCount(for: other) == 1 })
        await settle()
        #expect(fetcher.callCount(for: other) == 1)
    }

    @Test("Each picture is tracked on its own")
    func picturesAreIndependent() async {
        let (loader, fetcher) = makeLoader()

        _ = loader.state(for: url)
        _ = loader.state(for: other)

        await fetcher.complete(url, with: nil)
        await fetcher.complete(other, with: Image(systemName: "photo"))

        #expect(isFailed(loader.state(for: url)))
        #expect(isLoaded(loader.state(for: other)))
        #expect(fetcher.callCount == 2)
    }
}
