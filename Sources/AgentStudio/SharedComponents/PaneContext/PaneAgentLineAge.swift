import AgentStudioInfrastructure
import SwiftUI

package struct PaneAgentLineAge: View {
    private let text: String
    private let identifier: String?

    package init(_ text: String, identifier: String? = nil) {
        self.text = text
        self.identifier = identifier
    }

    static func styledText(_ text: String) -> Text {
        Text(" " + text)
            .font(.system(size: AppStyles.Shell.Sidebar.branchFontSize))
            .foregroundColor(.secondary)
    }

    package var body: some View {
        Self.styledText(text)
            .lineLimit(1)
            .fixedSize()
            .background {
                if let identifier {
                    AccessibilityLabelBridge(identifier: identifier, label: text, role: .staticText)
                }
            }
    }
}

/// Keeps the sidebar's whole suffix while clamping, or flows it after wrapping text.
package struct PaneAgentLineText: View {
    private let text: Text
    private let ageText: String
    private let maximumTextWidth: CGFloat
    private let wraps: Bool
    private let ageIdentifier: String?

    package init(
        _ text: Text, ageText: String, maximumTextWidth: CGFloat = .infinity,
        wraps: Bool = false, ageIdentifier: String? = nil
    ) {
        self.text = text
        self.ageText = ageText
        self.maximumTextWidth = maximumTextWidth
        self.wraps = wraps
        self.ageIdentifier = ageIdentifier
    }

    package var body: some View {
        if wraps {
            Text("\(text)\(PaneAgentLineAge.styledText(ageText))")
                .fixedSize(horizontal: false, vertical: true)
        } else {
            AdjacentAgeLayout(maximumTextWidth: maximumTextWidth) {
                text
                PaneAgentLineAge(ageText, identifier: ageIdentifier)
            }
        }
    }
}
