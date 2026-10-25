import AgentStudioInfrastructure
import Foundation
import SwiftUI

package struct AgentLinePopover: View {
    private let model: AgentLinePopoverModel
    private let goToPaneControl: PaneContextControlModel
    private let onGoToPane: @MainActor () -> Void
    private let feedback: String?
    package init(
        model: AgentLinePopoverModel,
        goToPaneControl: PaneContextControlModel, feedback: String? = nil,
        onGoToPane: @escaping @MainActor () -> Void
    ) {
        self.model = model
        self.goToPaneControl = goToPaneControl
        self.onGoToPane = onGoToPane
        self.feedback = feedback
    }
    package var body: some View {
        PaneContextPopoverPanel {
            if let feedback { PaneContextPopoverNote(feedback) }
            PaneContextDatedText(body: model.summary, age: model.age).font(.headline)
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
        } footer: {
            PaneContextActionButton(goToPaneControl, action: onGoToPane)
        }
    }
}
