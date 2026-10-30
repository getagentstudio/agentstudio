import AgentStudioInfrastructure
import SwiftUI

package struct PaneAgentLineAge: View {
    private let text: String
    private let identifier: String?

    package init(_ text: String, identifier: String? = nil) {
        self.text = text
        self.identifier = identifier
    }

    package var body: some View {
        Text(" " + text)
            .font(.system(size: AppStyles.Shell.Sidebar.branchFontSize))
            .foregroundStyle(Color.secondary)
            .lineLimit(1)
            .fixedSize()
            .background {
                if let identifier {
                    AccessibilityLabelBridge(identifier: identifier, label: text, role: .staticText)
                }
            }
    }
}
