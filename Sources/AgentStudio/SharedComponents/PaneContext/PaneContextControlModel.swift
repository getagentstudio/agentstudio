import AgentStudioInfrastructure
import Foundation

package struct PaneContextControlModel: Sendable, Equatable {
    package enum Icon: Sendable, Equatable {
        case system(String)
        case octicon(String)
    }
    package let identifier: String
    package let label: String
    package let icon: Icon
    package let tooltip: ControlTooltipRenderValue
    package init(identifier: String, label: String, icon: Icon, tooltip: ControlTooltipRenderValue) {
        self.identifier = identifier
        self.label = label
        self.icon = icon
        self.tooltip = tooltip
    }
    package func identifier(in scope: String?) -> String {
        guard let scope else { return identifier }
        return "\(identifier).\(scope)"
    }
}

package struct MessageFilterControlModel: Sendable, Equatable {
    package let attentionType: MessageAttentionTypeModel?
    package let control: PaneContextControlModel
    package init(attentionType: MessageAttentionTypeModel?, control: PaneContextControlModel) {
        self.attentionType = attentionType
        self.control = control
    }
}

package struct PaneContextPopoverControls: Sendable, Equatable {
    package let messages: PaneContextControlModel
    package let messageDetails: PaneContextControlModel
    package let answer: PaneContextControlModel
    package let dismiss: PaneContextControlModel
    package let dismissAllNotices: PaneContextControlModel
    package let markRead: PaneContextControlModel
    package let goToPane: PaneContextControlModel
    package let openFile: PaneContextControlModel
    package let openPullRequest: PaneContextControlModel
    package let moreMessages: PaneContextControlModel
    package let moreSources: PaneContextControlModel
    package let filters: [MessageFilterControlModel]
    package init(
        messages: PaneContextControlModel, messageDetails: PaneContextControlModel, answer: PaneContextControlModel,
        dismiss: PaneContextControlModel, dismissAllNotices: PaneContextControlModel,
        markRead: PaneContextControlModel, goToPane: PaneContextControlModel,
        openFile: PaneContextControlModel, openPullRequest: PaneContextControlModel,
        moreMessages: PaneContextControlModel,
        moreSources: PaneContextControlModel, filters: [MessageFilterControlModel]
    ) {
        self.messages = messages
        self.messageDetails = messageDetails
        self.answer = answer
        self.dismiss = dismiss
        self.dismissAllNotices = dismissAllNotices
        self.markRead = markRead
        self.goToPane = goToPane
        self.openFile = openFile
        self.openPullRequest = openPullRequest
        self.moreMessages = moreMessages
        self.moreSources = moreSources
        self.filters = filters
    }
}

package enum PaneContextPopoverLocation: Sendable, Equatable {
    case pane
    case sidebar
}

package struct AskFormDraft: Sendable, Equatable {
    package private(set) var selectedChoices: [String] = []
    package var text = ""
    package var fields: [String: String] = [:]
    package var booleans: [String: Bool] = [:]
    package init() {}

    package var booleanAnswers: [String: ElicitationValueModel] { booleans.mapValues { .boolean($0) } }
    /// This edits local control state; answer validation belongs to the person seam.
    package mutating func setChoice(_ id: String, selected: Bool, allowsMultiple: Bool) {
        if selected {
            if !allowsMultiple {
                selectedChoices = [id]
            } else if !selectedChoices.contains(id) {
                selectedChoices.append(id)
            }
        } else if let index = selectedChoices.firstIndex(of: id) {
            selectedChoices.remove(at: index)
        }
    }
}

package enum PaneContextChipTone: Sendable, Equatable {
    case neutral
    case info
    case success
    case warning
    case danger
}
