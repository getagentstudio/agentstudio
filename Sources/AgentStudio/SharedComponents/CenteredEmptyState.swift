import SwiftUI

/// Passive secondary text centered in the area its host provides.
package struct CenteredEmptyState: View {
    private let message: String
    private let identifier: String?

    package init(_ message: String, identifier: String? = nil) {
        self.message = message
        self.identifier = identifier
    }

    package var body: some View {
        VStack {
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .background {
                    if let identifier {
                        AccessibilityLabelBridge(identifier: identifier, label: message, role: .staticText)
                    }
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
