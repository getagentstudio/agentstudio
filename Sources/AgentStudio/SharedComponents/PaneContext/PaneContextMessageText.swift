import AgentStudioInfrastructure
import SwiftUI

package struct PaneContextMessageText: View {
    private let messageBody: String
    private let explanation: String?
    private let age: AgeTextModel
    private let identifier: String

    package init(body: String, explanation: String? = nil, age: AgeTextModel, identifier: String) {
        messageBody = body
        self.explanation = explanation
        self.age = age
        self.identifier = identifier
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
            AccessibilityLabelBridge(identifier: identifier, label: accessibleText, role: .staticText)
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
