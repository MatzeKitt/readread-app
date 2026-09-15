import Foundation
import SwiftData

/// This device's sync bookkeeping.
///
/// The pull cursor lives in the store rather than `UserDefaults` so it can be saved in the **same
/// transaction** as the records it accounts for. Split across two stores, a crash between them
/// would either re-apply changes (harmless) or, in the other order, skip them permanently.
@Model
public final class SyncState {

    /// Single row. A fixed id rather than a `UUID` so it is trivially findable.
    #Unique<SyncState>([\.id])
    public var id: String = "default"

    /// Highest revision applied from a **pull**.
    ///
    /// Never advanced from a push response: another device may hold a lower revision this device
    /// has not pulled, and adopting the push's `maxRevision` would skip it forever.
    public var pullCursor: Int = 0

    public var lastPulledAt: Date?
    public var lastPushedAt: Date?

    /// Last failure, for the settings screen. Cleared on the next success.
    public var lastErrorDescription: String?

    public init(id: String = "default") {
        self.id = id
    }
}
