import AgentStudioInfrastructure
import SwiftUI

/// Caps text from first paint and reveals disclosure only after its count is prepared.
struct PaneContextExpandableMessageBody: View {
    let text: String
    let font: PaneContextMessageBodyFont
    let layout: PaneContextMessageBodyLayout
    @Binding var isExpanded: Bool
    let less: PaneContextControlModel
    let scope: String
    let onGeometry: @MainActor (PaneContextMessageBodyGeometry) -> Void
    @Environment(\.fontResolutionContext) private var fontContext
    @State private var geometry: PaneContextMessageBodyGeometry?

    var body: some View {
        VStack(alignment: .leading, spacing: AppStyles.General.Spacing.standard) {
            Text(text)
                .font(font.paintFont)
                .lineSpacing(font.lineSpacing)
                .foregroundStyle(.primary)
                .lineLimit(isExpanded ? nil : AppPolicies.PaneContext.collapsedMessageBodyLines)
                .frame(maxWidth: .infinity, alignment: .leading)
            if isExpanded {
                disclosure(less)
            } else if case .ready(let measured, _, let more?) = layout, measured == geometry {
                disclosure(more)
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

    private func disclosure(_ control: PaneContextControlModel) -> some View {
        PaneContextActionButton(control, role: .alternative, scope: scope) { isExpanded.toggle() }
    }
}
