import AgentStudioInfrastructure
import Foundation
import SwiftUI

package struct AgentLinePopover: View {
    private let model: AgentLinePopoverModel
    private let providerPrompts: ProviderPromptsModel?
    private let goToPaneControl: PaneContextControlModel
    private let onGoToPane: @MainActor () -> Void
    package init(
        model: AgentLinePopoverModel, providerPrompts: ProviderPromptsModel? = nil,
        goToPaneControl: PaneContextControlModel, onGoToPane: @escaping @MainActor () -> Void
    ) {
        self.model = model
        self.providerPrompts = providerPrompts
        self.goToPaneControl = goToPaneControl
        self.onGoToPane = onGoToPane
    }
    package var body: some View {
        PopoverPanel {
            Text(model.summary).font(.headline)
            ForEach(model.refs.indices, id: \.self) { index in
                switch model.refs[index] {
                case .openFile(let path, let line):
                    Text(path)
                    if let line { Text("Line \(line)").font(.caption) }
                case .openPullRequest(let identity):
                    Text("\(identity.owner)/\(identity.repository) #\(identity.number)")
                case .goToPane: Text("Related pane")
                }
            }
            MessageSenderLabel(sender: model.writer)
            Text(model.updatedAt, style: .relative).font(.caption)
            if let providerPrompts { ProviderPromptRows(model: providerPrompts) }
            PaneContextActionButton(goToPaneControl, action: onGoToPane)
        }
    }
}
