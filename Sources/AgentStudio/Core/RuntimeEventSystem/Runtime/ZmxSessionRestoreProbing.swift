import Foundation

/// What the launch-restore decision (SR1, SR2; Program Design item 1) needs
/// from zmx, abstracted so `mount()`'s kind resolution is testable without a
/// real zmx binary. `ZmxBackend` is the production conformer.
///
/// `observeSessionIdentity` is the same method
/// `WorkspaceSurfaceCoordinator+SessionCleanup` already calls for verified
/// retirement — reused here for the warm baseline (choice 1), not
/// duplicated.
package protocol ZmxSessionRestoreProbing: Sendable {
    /// One bounded `zmx list` probe of the whole zmx directory (SR1, SR2).
    func discoverSessionInventory() async -> ZmxSessionInventory
    /// Nil means the exact endpoint is positively absent, not a failed
    /// inspection.
    func observeSessionIdentity(_ sessionID: ZmxSessionID) async throws -> Data?
}
