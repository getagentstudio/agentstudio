import AgentStudioInfrastructure
import SwiftUI

package struct PaneContextMessageText: View {
    private struct PlainText {
        let body: String
        let font: PaneContextMessageBodyFont
        let explanation: String?
        let age: AgeTextModel
        let identifier: String
    }
    private struct PreparedText {
        let value: PaneContextMessageTextValue
        let application: PaneContextMessageTextApplication?
        let octiconLoader: OcticonLoader
        let isDetailsSelected: Bool
        let onDetails: @MainActor () -> Void
    }
    private enum Content {
        case plain(PlainText)
        case prepared(PreparedText)
    }
    private let content: Content
    private let onBodyGeometry: @MainActor (PaneContextTextBodyKey, PaneContextMessageBodyGeometry) -> Void

    package init(
        body: String,
        bodyFont: PaneContextMessageBodyFont = .proportional(pointSize: AppStyles.General.Typography.textSm),
        explanation: String? = nil, age: AgeTextModel, identifier: String
    ) {
        content = .plain(.init(body: body, font: bodyFont, explanation: explanation, age: age, identifier: identifier))
        onBodyGeometry = { _, _ in }
    }

    package init(
        value: PaneContextMessageTextValue, application: PaneContextMessageTextApplication? = nil,
        octiconLoader: OcticonLoader, isDetailsSelected: Bool = false, onDetails: @escaping @MainActor () -> Void,
        onBodyGeometry: @escaping @MainActor (PaneContextTextBodyKey, PaneContextMessageBodyGeometry) -> Void
    ) {
        content = .prepared(
            .init(
                value: value, application: application, octiconLoader: octiconLoader,
                isDetailsSelected: isDetailsSelected, onDetails: onDetails))
        self.onBodyGeometry = onBodyGeometry
    }

    private var messageBody: String {
        switch content {
        case .plain(let text): text.body
        case .prepared(let text): text.value.body
        }
    }
    private var explanation: String? {
        switch content {
        case .plain(let text): text.explanation
        case .prepared(let text): text.value.explanation
        }
    }
    private var age: AgeTextModel {
        switch content {
        case .plain(let text): text.age
        case .prepared(let text): text.value.age
        }
    }
    private var identifier: String {
        switch content {
        case .plain(let text): text.identifier
        case .prepared(let text): text.value.key.textIdentifier
        }
    }
    private var labelApplication: AccessibilityLabelApplication? {
        if case .prepared(let text) = content {
            return text.application?.labelApplication(for: text.value)
        }
        return nil
    }

    package var body: some View {
        VStack(alignment: .leading, spacing: AppStyles.General.Spacing.tight) {
            switch content {
            case .prepared(let text):
                PaneContextTruncatedMessageBody(
                    text: text.value.bodyText.paint, font: text.value.bodyFont, layout: text.value.bodyLayout,
                    octiconLoader: text.octiconLoader, onDetails: text.onDetails,
                    isDetailsSelected: text.isDetailsSelected, scope: identifier,
                    onGeometry: { onBodyGeometry(text.value.key, $0) })
            case .plain(let text):
                Text(messageBody).font(text.font.paintFont).lineSpacing(text.font.lineSpacing)
                    .foregroundStyle(.primary)
            }
            if let explanation {
                Text(explanation).font(.system(size: AppStyles.General.Typography.textSm)).foregroundStyle(.secondary)
            }
            Text(age.text).font(.system(size: AppStyles.General.Typography.textSm)).foregroundStyle(.secondary)
        }
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .background {
            AccessibilityLabelBridge(
                identifier: identifier, label: accessibleText, role: .staticText, application: labelApplication)
        }
    }

    private var accessibleText: String { messageBody + (explanation.map { "\n" + $0 } ?? "") + " " + age.text }
}

struct PaneContextRowGlyph: View {
    let icon: PaneContextControlModel.Icon
    let style: SidebarChip.Style
    let octiconLoader: OcticonLoader

    var body: some View {
        Group {
            switch icon {
            case .system(let symbol):
                Image(systemName: symbol).font(.system(size: AppStyles.General.Icon.compact))
            case .octicon(let symbol):
                OcticonImage(name: symbol, size: AppStyles.General.Icon.compact, loader: octiconLoader)
            }
        }
        .foregroundStyle(style.foreground)
        .frame(
            width: AppStyles.Components.PaneContext.messageGlyphBoxSize,
            height: AppStyles.Components.PaneContext.messageGlyphBoxSize
        )
        .accessibilityHidden(true)
    }
}
