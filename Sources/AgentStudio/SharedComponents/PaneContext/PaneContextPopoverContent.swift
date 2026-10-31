import AgentStudioInfrastructure
import SwiftUI

package enum PaneContextPopoverPanelAnchor: Hashable, Sendable { case top }

package struct PaneContextPopoverHeightWrite: Equatable, Sendable {
    package enum Region: Equatable, Sendable { case header, rows, footer }
    package let region: Region
    package let height: CGFloat
}

package struct PaneContextDatedText: View {
    private let text: AttributedString
    private let identifier: String?
    private let application: AccessibilityLabelApplication?
    package init(
        body: String, explanation: String? = nil, age: AgeTextModel, identifier: String? = nil,
        application: AccessibilityLabelApplication? = nil
    ) {
        self.identifier = identifier
        self.application = application
        var text = AttributedString(body)
        if let explanation {
            var explanationText = AttributedString("\n" + explanation)
            explanationText.foregroundColor = .secondary
            text.append(explanationText)
        }
        var ageText = AttributedString(" " + age.text)
        ageText.foregroundColor = .secondary
        text.append(ageText)
        self.text = text
    }
    package var body: some View {
        Text(text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true).background {
            if let identifier {
                AccessibilityLabelBridge(
                    identifier: identifier, label: String(text.characters), role: .staticText, application: application)
            }
        }
    }
}

package struct PaneContextPopoverNote: View {
    private let text: String
    package init(_ text: String) { self.text = text }
    package var body: some View {
        Text(text).foregroundStyle(.secondary).background {
            AccessibilityLabelBridge(identifier: "pane-context.feedback", label: text, role: .staticText)
        }
    }
}
