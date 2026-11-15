import Foundation

/// Correlates a native accessibility value with its producer and exact prepared frame.
package struct AccessibilityLabelApplication {
    package struct Key: Equatable, Sendable {
        package let producerId: UUID
        package let valueId: UUID
        package init(producerId: UUID, valueId: UUID) {
            self.producerId = producerId
            self.valueId = valueId
        }
    }
    package struct Value: Equatable, Sendable {
        package let key: Key
        package let identifier: String
        package let label: String
    }
    package enum Event: Equatable, Sendable {
        case applied(Value)
        case retired(Value)
        /// The eligible native update ended even if its applied receipt was missing.
        case updateEnded(Key)
    }
    let key: Key
    let observe: @MainActor (Event) -> Void
    package init(key: Key, observe: @escaping @MainActor (Event) -> Void) {
        self.key = key
        self.observe = observe
    }
}
