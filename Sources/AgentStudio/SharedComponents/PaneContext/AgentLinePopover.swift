import AgentStudioInfrastructure
import Foundation
import SwiftUI

package struct AgentLinePopover: View {
    package static let datedLabelIdentifier = "pane-context.agent-line-dated-text"
    private let octiconLoader: OcticonLoader
    private let model: AgentLinePopoverModel
    private let goToPaneControl: PaneContextControlModel
    private let onGoToPane: @MainActor () -> Void
    private let feedback: String?
    private let labelApplication: AccessibilityLabelApplication?
    package init(
        model: AgentLinePopoverModel, octiconLoader: OcticonLoader,
        goToPaneControl: PaneContextControlModel, feedback: String? = nil,
        labelApplication: AccessibilityLabelApplication? = nil,
        onGoToPane: @escaping @MainActor () -> Void
    ) {
        self.model = model
        self.octiconLoader = octiconLoader
        self.goToPaneControl = goToPaneControl
        self.onGoToPane = onGoToPane
        self.feedback = feedback
        self.labelApplication = labelApplication
    }
    package var body: some View {
        PopoverPanel(
            width: AppStyles.Components.PaneContext.popoverWidth,
            maximumHeight: AppStyles.Components.PaneContext.popoverMaximumHeight,
            identifier: "pane-context.popover-panel"
        ) {
            VStack(alignment: .leading, spacing: 0) {
                PaneContextDatedText(
                    body: model.summary, age: model.age, identifier: Self.datedLabelIdentifier,
                    application: labelApplication
                ).font(.headline)
                    .padding(.bottom, AppStyles.Components.PopoverPanel.contentPadding)
                Divider().opacity(0)
                VStack(alignment: .leading, spacing: AppStyles.Components.PopoverPanel.sectionSpacing) {
                    if let feedback { PaneContextPopoverNote(feedback) }
                    MessageSenderLabel(sender: model.writer)
                    ForEach(model.refs.indices, id: \.self) { index in
                        switch model.refs[index] {
                        case .openFile(let path, let line):
                            Text(path).textSelection(.enabled)
                            if let line { Text("Line \(line)").font(.caption).textSelection(.enabled) }
                        case .openPullRequest(let identity):
                            Text("\(identity.owner)/\(identity.repository) #\(identity.number)").textSelection(.enabled)
                        case .goToPane: Text("Related pane").textSelection(.enabled)
                        }
                    }
                }
            }
        } footer: {
            PaneContextActionButton(goToPaneControl, role: .utility(octiconLoader), action: onGoToPane)
        }
    }
}
