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
        Text(" " + unbrokenText(text))
            .font(.system(size: AppStyles.Shell.Sidebar.branchFontSize))
            .foregroundColor(.secondary)
    }

    static func unbrokenText(_ text: String) -> String {
        text.replacingOccurrences(of: " ", with: "\u{00a0}")
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
    private let summaryReadout: (identifier: String, label: String)?
    private let ageIdentifier: String?

    package init(
        _ text: Text, ageText: String, maximumTextWidth: CGFloat = .infinity,
        wraps: Bool = false, summaryReadout: (identifier: String, label: String)? = nil, ageIdentifier: String? = nil
    ) {
        self.text = text
        self.ageText = ageText
        self.maximumTextWidth = maximumTextWidth
        self.wraps = wraps
        self.summaryReadout = summaryReadout
        self.ageIdentifier = ageIdentifier
    }

    package var body: some View {
        if wraps {
            Text("\(text)\(PaneAgentLineAge.styledText(ageText))")
                .fixedSize(horizontal: false, vertical: true)
        } else {
            AdjacentAgeLayout(maximumTextWidth: maximumTextWidth) {
                text
                    .background {
                        if let summaryReadout {
                            AccessibilityLabelBridge(
                                identifier: summaryReadout.identifier, label: summaryReadout.label, role: .staticText)
                        }
                    }
                PaneAgentLineAge(ageText, identifier: ageIdentifier)
            }
        }
    }
}
