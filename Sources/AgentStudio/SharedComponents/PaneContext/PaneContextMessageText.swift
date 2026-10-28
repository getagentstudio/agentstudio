import AgentStudioInfrastructure
import SwiftUI

package struct PaneContextMessageText: View {
    private enum Content {
        case plain(body: String, explanation: String?, age: AgeTextModel, identifier: String)
        case message(PaneContextMessageTextValue, PaneContextMessageTextApplication?)
    }
    private let content: Content

    package init(body: String, explanation: String? = nil, age: AgeTextModel, identifier: String) {
        content = .plain(body: body, explanation: explanation, age: age, identifier: identifier)
    }

    package init(value: PaneContextMessageTextValue, application: PaneContextMessageTextApplication? = nil) {
        content = .message(value, application)
    }

    private var messageBody: String {
        switch content {
        case .plain(let body, _, _, _): body
        case .message(let row, _): row.body
        }
    }
    private var explanation: String? {
        switch content {
        case .plain(_, let why, _, _): why
        case .message(let row, _): row.explanation
        }
    }
    private var age: AgeTextModel {
        switch content {
        case .plain(_, _, let age, _): age
        case .message(let row, _): row.age
        }
    }
    private var identifier: String {
        switch content {
        case .plain(_, _, _, let identifier): identifier
        case .message(let row, _): "pane-context.message-text." + row.key.controlScope
        }
    }
    private var labelApplication: AccessibilityLabelApplication? {
        if case .message(let row, let application) = content { return application?.labelApplication(for: row) }
        return nil
    }

    package var body: some View {
        VStack(alignment: .leading, spacing: AppStyles.General.Spacing.tight) {
            Text(messageBody)
                .font(
                    .system(
                        size: hasLineBreak ? AppStyles.General.Typography.textXs : AppStyles.General.Typography.textSm,
                        design: hasLineBreak ? .monospaced : .default)
                )
                .lineSpacing(
                    hasLineBreak
                        ? AppStyles.Components.PaneContext.monospacedLineSpacing
                        : AppStyles.Components.PaneContext.bodyLineSpacing
                )
                .foregroundStyle(.primary)
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

    private var hasLineBreak: Bool { messageBody.contains(where: \.isNewline) }
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
