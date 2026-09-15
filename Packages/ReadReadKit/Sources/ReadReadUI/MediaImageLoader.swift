import Foundation
import Observation
import SwiftUI

/// Loads the full-size pictures for one opening of ``MediaViewer``.
///
/// Exists because `AsyncImage` cannot be paged through. Its load belongs to its view, and a page
/// that scrolls out of the viewer takes its own load down with it — but SwiftUI keeps the page's
/// `@State`, so the cancelled attempt comes back as a latched `.failure` the next time that page
/// scrolls in. `AsyncImage` will not retry, because from its side nothing changed: same view, same
/// URL, already resolved. The result was a picture that read "could not be loaded" after two taps
/// of an arrow key and then loaded perfectly when the viewer was opened on it directly, which is
/// exactly the shape of a cancellation being reported as a failure.
///
/// So the load is deliberately **not** owned by a view. It runs in a detached task, records what
/// it found, and there is nothing for a scroll to cancel.
///
/// Held as viewer state rather than shared, so the pictures are released when the viewer closes.
/// A handful of decoded full-size images is a lot of memory to keep for a session; it is nothing
/// to keep while someone is looking at them.
@MainActor
@Observable
final class MediaImageLoader {

    enum State {
        case loading
        case loaded(Image)
        /// Fetched, and there was nothing usable there. Distinct from `loading` so the viewer can
        /// say so and offer to try again, rather than spinning forever.
        case failed
    }

    private var states: [URL: State] = [:]
    @ObservationIgnored private var inFlight: Set<URL> = []
    @ObservationIgnored private let fetch: @Sendable (URL) async -> Image?

    /// A photograph, not an icon. Generous enough for anything a Mastodon instance will serve, and
    /// still a ceiling — a mis-linked video would otherwise be pulled in full to be decoded as an
    /// image and thrown away.
    static let maximumBytes = 25 * 1024 * 1024

    init(fetch: (@Sendable (URL) async -> Image?)? = nil) {
        self.fetch = fetch ?? { url in
            await RemoteImageStore.fetch(url, session: .shared, maximumBytes: Self.maximumBytes)
        }
    }

    /// What is known about this image, starting the load on the first ask.
    ///
    /// Starting it here is deliberate, the same bargain `RemoteImageStore` makes: giving the caller
    /// a separate "please load this" call to remember is how a page ends up never asking.
    func state(for url: URL) -> State {
        if let known = states[url] { return known }
        load(url)
        return .loading
    }

    /// Asks again for one that failed.
    func retry(_ url: URL) {
        guard case .failed = states[url] else { return }
        states[url] = nil
        load(url)
    }

    private func load(_ url: URL) {
        // A second page asking for the same picture — the same image attached twice, or a re-ask
        // after the state was read — must not start a second download.
        guard !inFlight.contains(url) else { return }
        inFlight.insert(url)

        let fetch = fetch
        Task { [weak self] in
            let image = await fetch(url)
            self?.finish(url, with: image)
        }
    }

    private func finish(_ url: URL, with image: Image?) {
        inFlight.remove(url)
        states[url] = image.map(State.loaded) ?? .failed
    }
}
