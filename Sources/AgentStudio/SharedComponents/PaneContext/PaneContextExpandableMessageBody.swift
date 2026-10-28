import AgentStudioInfrastructure
import AppKit
import SwiftUI

/// Keep the existing SwiftUI paint and controls; native text layout counts wrapped visual lines.
struct PaneContextExpandableMessageBody: View {
    let text: String
    @Binding var isExpanded: Bool
    let more: PaneContextControlModel
    let less: PaneContextControlModel
    let scope: String
    @State private var availableWidth: CGFloat = 0

    private var multiline: Bool { text.contains(where: \.isNewline) }
    private var fontSize: CGFloat {
        multiline ? AppStyles.General.Typography.textXs : AppStyles.General.Typography.textSm
    }
    private var lineSpacing: CGFloat {
        multiline
            ? AppStyles.Components.PaneContext.monospacedLineSpacing : AppStyles.Components.PaneContext.bodyLineSpacing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppStyles.General.Spacing.standard) {
            Text(text)
                .font(.system(size: fontSize, design: multiline ? .monospaced : .default))
                .lineSpacing(lineSpacing)
                .foregroundStyle(.primary)
                .lineLimit(isExpanded ? nil : AppPolicies.PaneContext.collapsedMessageBodyLines)
                .frame(maxWidth: .infinity, alignment: .leading)
            let hidden = max(0, visualLineCount - AppPolicies.PaneContext.collapsedMessageBodyLines)
            if hidden > 0 {
                PaneContextActionButton(disclosureControl(hidden: hidden), role: .alternative, scope: scope) {
                    isExpanded.toggle()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width
        } action: {
            availableWidth = $0
        }
    }

    private func disclosureControl(hidden: Int) -> PaneContextControlModel {
        let control = isExpanded ? less : more
        return .init(
            identifier: control.identifier,
            label: isExpanded ? control.label : String(format: control.label, hidden),
            icon: control.icon, tooltip: control.tooltip)
    }

    private var visualLineCount: Int {
        guard availableWidth > 0 else { return 0 }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        paragraph.lineBreakMode = .byWordWrapping
        let font: NSFont =
            multiline
            ? .monospacedSystemFont(ofSize: fontSize, weight: .regular) : .systemFont(ofSize: fontSize)
        let storage = NSTextStorage(string: text, attributes: [.font: font, .paragraphStyle: paragraph])
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: .init(width: availableWidth, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        manager.ensureLayout(for: container)
        var count = 0
        manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: container)) { _, _, _, _, _ in count += 1
        }
        if text.last?.isNewline == true { count += 1 }
        return count
    }
}
