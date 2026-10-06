import AgentStudioInfrastructure
import Foundation
import SwiftUI

package struct GitPRSummaryPopover: View {
    private let model: GitPRSummaryPopoverModel
    private let presentation: GitPRSummaryPresentationModel
    private let controls: PaneContextPopoverControls
    private let feedback: String?
    private let onGoToPane: @MainActor () -> Void
    private let onOpenPullRequest: (@MainActor (UUID, Int) -> Void)?
    package init(
        model: GitPRSummaryPopoverModel, presentation: GitPRSummaryPresentationModel,
        controls: PaneContextPopoverControls, feedback: String? = nil, onGoToPane: @escaping @MainActor () -> Void,
        onOpenPullRequest: (@MainActor (UUID, Int) -> Void)? = nil
    ) {
        self.model = model
        self.presentation = presentation
        self.controls = controls
        self.feedback = feedback
        self.onGoToPane = onGoToPane
        self.onOpenPullRequest = onOpenPullRequest
    }
    package var body: some View {
        PopoverPanel {
            PopoverPanelSectionHeader(presentation.header)
            if let feedback { Text(feedback).foregroundStyle(.secondary) }
            ForEach(model.members.indices, id: \.self) { index in
                VStack(alignment: .leading, spacing: AppStyles.General.Spacing.tight) {
                    switch model.members[index] {
                    case .noPullRequest:
                        Text("Worktree · no pull request")
                    case .unknown:
                        Text("Worktree · pull request information unavailable")
                    case .pullRequest(let worktree, let number, let checks, let review):
                        Text("Pull request #\(number)").font(.headline)
                        Text(Self.checksText(checks))
                        Text(Self.reviewText(review))
                        if let onOpenPullRequest {
                            PaneContextActionButton(controls.openPullRequest, scope: worktree.uuidString) {
                                onOpenPullRequest(worktree, number)
                            }
                        }
                    }
                    Divider()
                }
            }
            PaneContextActionButton(controls.goToPane, action: onGoToPane)
        }
    }
    private static func checksText(_ checks: PullRequestChecksModel) -> String {
        switch checks {
        case .passed: "Checks passed"
        case .running: "Checks running"
        case .failed: "Checks failed"
        case .unknown: "Checks unknown"
        }
    }
    private static func reviewText(_ review: PullRequestReviewModel) -> String {
        switch review {
        case .approved: "Review approved"
        case .changesRequested: "Changes requested"
        case .reviewRequired: "Review required"
        case .unknown: "Review unknown"
        }
    }
}
