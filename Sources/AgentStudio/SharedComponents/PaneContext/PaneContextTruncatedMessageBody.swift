import AgentStudioInfrastructure
import SwiftUI

/// Caps text from first paint and reveals disclosure only after its count is prepared.
struct PaneContextTruncatedMessageBody: View {
    let text: AttributedString
    let font: PaneContextMessageBodyFont
    let layout: PaneContextMessageBodyLayout
    let octiconLoader: OcticonLoader
    let onDetails: @MainActor () -> Void
    let isDetailsSelected: Bool
    let scope: String
    let onGeometry: @MainActor (PaneContextMessageBodyGeometry) -> Void
    @Environment(\.fontResolutionContext) private var fontContext
    @State private var geometry: PaneContextMessageBodyGeometry?

    private var displayText: AttributedString {
        if case .ready(let measured, _, _, let preview?) = layout, measured == geometry { return preview }
        return text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppStyles.General.Spacing.standard) {
            Text(displayText)
                .font(font.paintFont)
                .lineSpacing(font.lineSpacing)
                .foregroundStyle(.primary)
                .lineLimit(AppPolicies.PaneContext.collapsedMessageBodyLines)
                .frame(maxWidth: .infinity, alignment: .leading)
            if case .ready(let measured, _, let details?, _) = layout, measured == geometry {
                PaneContextActionButton(
                    details, role: .details(octiconLoader), scope: scope, isSelected: isDetailsSelected,
                    action: onDetails)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: PaneContextMessageBodyGeometry.self) {
            .init(effectiveWidth: $0.size.width, fontContext: fontContext)
        } action: { capture in
            geometry = capture
            onGeometry(capture)
        }
        .onChange(of: fontContext) { _, changed in
            guard let geometry else { return }
            let capture = PaneContextMessageBodyGeometry(effectiveWidth: geometry.effectiveWidth, fontContext: changed)
            self.geometry = capture
            onGeometry(capture)
        }
    }

}
