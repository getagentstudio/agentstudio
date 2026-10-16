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
            switch model.work {
            case .working(.indeterminate): Text("Working")
            case .working(.step(let current, let total)): Text("Working · step \(current) of \(total)")
            case .monitoring(let subject): Text("Monitoring · \(subject)")
            case .blockedOnYou(let action): Text("Blocked on you · \(action)")
            case .done: Text("Done")
            case .failed(let summary): Text("Failed · \(summary)")
            }
            if let detail = model.detail { Text(detail).textSelection(.enabled) }
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
            if model.stale { Text("Stale").foregroundStyle(.secondary) }
            if case .expires(let expiry) = model.lifetime {
                HStack {
                    Text("Expires")
                    Text(expiry, format: .dateTime)
                }.font(.caption)
            }
            if let providerPrompts { ProviderPromptRows(model: providerPrompts) }
            PaneContextActionButton(goToPaneControl, action: onGoToPane)
        }
        .opacity(model.stale ? AppStyles.General.Foreground.secondary : 1)
    }
}
