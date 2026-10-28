import Foundation

/// The row value that drives both dated text and its read dim.
package struct PaneContextMessageTextValue: Equatable, Sendable {
    package let key: MessageRowModel.Key
    package let body: String
    package let explanation: String?
    package let age: AgeTextModel
    package let isRead: Bool

    package init(row: MessageRowModel) {
        key = row.key
        body = row.body
        explanation = row.why
        age = row.age
        isRead = row.isDimmed
    }
}

/// Optional leaf receipts reuse the native AX assignment mechanism.
package struct PaneContextMessageTextApplication {
    package struct Value: Equatable, Sendable {
        package let row: PaneContextMessageTextValue
        package let native: AccessibilityLabelApplication.Value
    }
    package struct Update: Equatable, Sendable {
        package let row: PaneContextMessageTextValue
        package let key: AccessibilityLabelApplication.Key
    }
    package enum Event: Equatable, Sendable {
        case applied(Value)
        case retired(Value)
        case updateEnded(Update)
    }
    private let key: AccessibilityLabelApplication.Key
    private let observe: @MainActor (Event) -> Void

    package init(key: AccessibilityLabelApplication.Key, observe: @escaping @MainActor (Event) -> Void) {
        self.key = key
        self.observe = observe
    }

    @MainActor func labelApplication(for row: PaneContextMessageTextValue) -> AccessibilityLabelApplication {
        .init(key: key) { event in
            switch event {
            case .applied(let native): observe(.applied(.init(row: row, native: native)))
            case .retired(let native): observe(.retired(.init(row: row, native: native)))
            case .updateEnded(let key): observe(.updateEnded(.init(row: row, key: key)))
            }
        }
    }
}
