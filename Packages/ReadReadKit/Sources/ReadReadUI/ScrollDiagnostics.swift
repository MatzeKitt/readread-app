import Foundation

#if DEBUG
/// A log of what moved the timeline and why, in debug builds.
///
/// Every programmatic move goes through ``TimelineController``, which reports it here: opening a
/// scope, applying a snapshot, a settle being recorded, another device's position being adopted.
/// So when the list ends up somewhere unexpected, the log says which of those put it there — and
/// a move that does not appear in it was the reader's own.
@MainActor
final class ScrollDiagnostics {

    static let shared = ScrollDiagnostics()

    func event(_ text: String) {
        print("[readread-scroll] \(text)")
    }
}
#else
/// The same surface, compiled to nothing.
@MainActor
final class ScrollDiagnostics {

    static let shared = ScrollDiagnostics()

    func event(_ text: String) {}
}
#endif
