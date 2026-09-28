#if os(macOS)
import AppKit

/// Holds up quitting on the Mac until the last reading position has been sent.
///
/// `applicationShouldTerminate` is the only point in quitting where asynchronous work can still
/// finish: answering `.terminateLater` keeps the main run loop turning until the reply arrives.
/// `willTerminate`, which comes after it, is followed by the process exiting.
///
/// AppKit posts `willTerminate` only after this has agreed to quit, so every quit that used to
/// reach the old push reaches this one.
@MainActor
public final class QuitDelegate: NSObject, NSApplicationDelegate {

    /// Set by ``AppServices`` once it starts. Nil before that, in which case there is nothing
    /// queued to wait for.
    static weak var services: AppServices?

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let services = Self.services else { return .terminateNow }
        // The reply comes from a task, so always after this has returned `.terminateLater`.
        services.prepareToQuit {
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
#endif
