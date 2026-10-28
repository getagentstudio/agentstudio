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

package struct PaneContextPopoverControls: Sendable, Equatable {
    package let messages: PaneContextControlModel
    package let showMoreLines: PaneContextControlModel
    package let showFewerLines: PaneContextControlModel
    package let chooseOption: PaneContextControlModel
    package let requiredField: PaneContextControlModel
    package let filter: PaneContextControlModel
    package let filters: [PaneContextControlModel]
    package let submit: PaneContextControlModel
    package let dismiss: PaneContextControlModel
    package let dismissAllNotices: PaneContextControlModel
    package let goToPane: PaneContextControlModel
    package let openFile: PaneContextControlModel
    package let openPullRequest: PaneContextControlModel
    package let moreMessages: PaneContextControlModel
    package let moreSources: PaneContextControlModel
    package init(
        messages: PaneContextControlModel, showMoreLines: PaneContextControlModel,
        showFewerLines: PaneContextControlModel, chooseOption: PaneContextControlModel,
        requiredField: PaneContextControlModel, filter: PaneContextControlModel, filters: [PaneContextControlModel],
        submit: PaneContextControlModel,
        dismiss: PaneContextControlModel, dismissAllNotices: PaneContextControlModel,
        goToPane: PaneContextControlModel,
        openFile: PaneContextControlModel, openPullRequest: PaneContextControlModel,
        moreMessages: PaneContextControlModel,
        moreSources: PaneContextControlModel
    ) {
        self.messages = messages
        self.showMoreLines = showMoreLines
        self.showFewerLines = showFewerLines
        self.chooseOption = chooseOption
        self.requiredField = requiredField
        self.filter = filter
        self.filters = filters
        self.submit = submit
        self.dismiss = dismiss
        self.dismissAllNotices = dismissAllNotices
        self.goToPane = goToPane
        self.openFile = openFile
        self.openPullRequest = openPullRequest
        self.moreMessages = moreMessages
        self.moreSources = moreSources
    }
}

package enum PaneContextPopoverLocation: Sendable, Equatable {
    case pane
    case sidebar
    case card

    package func presentation(for interaction: PaneContextInteraction) -> PaneContextInteractionPresentation {
        switch self {
        case .sidebar, .pane:
            switch interaction {
            case .answer, .dismissAsk, .noticeActions: .inline
            }
        case .card:
            switch interaction {
            case .dismissAsk: .inline
            case .noticeActions: .notApplicable
            case .answer(let form):
                switch form {
                case .approval, .choice, .freeText: .inline
                case .elicitation: .inMessages
                }
            }
        }
    }
}

package enum PaneContextInteraction: Sendable, Equatable {
    case answer(AskFormModel)
    case dismissAsk
    case noticeActions
}

package enum PaneContextInteractionPresentation: Sendable, Equatable {
    case inline
    case inMessages
    case notApplicable
}

package struct AskFormDraft: Sendable, Equatable {
    package var approvalDecision: ApprovalDecisionModel?
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
    case accent
    case info
    case success
    case warning
    case danger
}
