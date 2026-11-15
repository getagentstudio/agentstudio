import Foundation

/// The row value that drives both dated text and its read dim.
package struct PaneContextMessageTextValue: Equatable, Sendable {
    package let key: PaneContextTextBodyKey
    package let body: String
    package let detailsTitle: String
    package let explanation: String?
    package let age: AgeTextModel
    package let isRead: Bool
    package let bodyFont: PaneContextMessageBodyFont
    package let bodyText: PaneContextMessageBodyText
    package let bodyLayout: PaneContextMessageBodyLayout

    package init(row: MessageRowModel) {
        key = .message(row.key)
        body = row.bodyText.plainText
        detailsTitle = row.detailsTitle
        explanation = row.why
        age = row.age
        isRead = row.isDimmed
        bodyFont = row.bodyFont
        bodyText = row.bodyText
        bodyLayout = row.bodyLayout
    }
    package init(prompt: ProviderPromptRowModel) {
        key = prompt.textBodyKey
        body = prompt.bodyText.plainText
        detailsTitle = prompt.detailsTitle
        explanation = nil
        age = prompt.age
        isRead = false
        bodyFont = prompt.bodyFont
        bodyText = prompt.bodyText
        bodyLayout = prompt.bodyLayout
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
