import Foundation

enum CLIStorePolicy {
    static let busyTimeout: TimeInterval = 0.05
    /// First-open migration waits for its sibling within the call budget; ordinary writes stay fail-open.
    static let firstOpenMigrationLockWaitCap: Duration = .seconds(1)
    /// Milliseconds since the Unix epoch, independent of local timezone.
    static let millisecondsPerSecond: Double = 1000
    /// Handled notices remain available for one day; unread rows have no expiry.
    static let handledRetention: TimeInterval = 86_400
}
