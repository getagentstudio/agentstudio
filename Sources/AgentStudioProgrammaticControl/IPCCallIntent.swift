import Foundation

package enum IPCCallIntent: String, Codable, CaseIterable, Equatable, Hashable, Sendable, IPCSchemaProviding {
    case status, identity, message, read, control

    /// A session-attributed writer retains identity intent on a pane-status method.
    package func effective(hasSessionWriter: Bool) -> Self {
        self == .status && hasSessionWriter ? .identity : self
    }
}
