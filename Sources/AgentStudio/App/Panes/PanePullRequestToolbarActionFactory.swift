import AgentStudioCore
import AgentStudioInfrastructure
import Foundation

@MainActor
struct PanePullRequestToolbarPresentation {
    let blockerIndicator: PaneSurfaceToolbarStatusIndicator?
    let openAction: PaneSurfaceToolbarAction
}

@MainActor
enum PanePullRequestToolbarActionFactory {
    static func makeList(_ list: PanePullRequestList, commandAction: TargetedCommandControlAction?)
        -> PanePullRequestToolbarPresentation?
    {
        guard let commandAction else { return nil }
        let spec = commandAction.commandSpec
        let tone: PaneSurfaceToolbarAction.IconStatusTone?
        switch list.worstChecks {
        case .failed?: tone = .danger
        case .running?: tone = .warning
        case .passed?: tone = .success
        case .unknown?, nil: tone = nil
        }
        return .init(
            blockerIndicator: nil,
            openAction: .init(
                state: .init(
                    label: spec.label, accessibilityIdentifier: "paneSurfaceToolbar.pullRequest", icon: spec.icon,
                    tooltip: spec.controlTooltipRenderValue(), isEnabled: !list.isEmpty && commandAction.isEnabled,
                    isSelected: false, visibleLabel: list.count > 1 ? String(list.count) : nil,
                    iconStatusTone: tone), perform: commandAction.perform))
    }

    private struct ActionPresentation {
        let accessibilityLabel: String
        let tooltip: ControlTooltipRenderValue
        let icon: CommandIcon
        let iconStatusTone: PaneSurfaceToolbarAction.IconStatusTone?
    }

    static func make(
        paneId: UUID,
        store: WorkspaceStore,
        repoCache: RepoCacheAtom,
        commandAction: TargetedCommandControlAction?
    ) -> PanePullRequestToolbarPresentation? {
        guard
            let commandAction,
            GitHubWebviewLaunchResolver.hasResolvableWorktreeContext(
                for: paneId,
                store: store
            )
        else { return nil }

        let commandSpec = commandAction.commandSpec
        let pullRequestFacts = GitHubWebviewLaunchResolver.pullRequestFacts(
            for: paneId,
            store: store,
            repoCache: repoCache
        )
        let exactPullRequestURL = pullRequestFacts?.exactOpenURL
        let presentation = presentation(for: pullRequestFacts, commandSpec: commandSpec)
        let isEnabled = exactPullRequestURL != nil && commandAction.isEnabled
        return PanePullRequestToolbarPresentation(
            blockerIndicator: blockerIndicator(for: pullRequestFacts?.exactReadiness),
            openAction: PaneSurfaceToolbarAction(
                state: PaneSurfaceToolbarAction.State(
                    label: presentation.accessibilityLabel,
                    accessibilityIdentifier: "paneSurfaceToolbar.pullRequest",
                    icon: presentation.icon,
                    tooltip: presentation.tooltip,
                    isEnabled: isEnabled,
                    isSelected: false,
                    selectionEmphasis: .standard,
                    iconStatusTone: isEnabled ? presentation.iconStatusTone : nil
                ),
                perform: {
                    guard isEnabled else { return }
                    commandAction.perform()
                }
            ),
        )
    }

    private static func presentation(
        for pullRequestFacts: PullRequestFacts?,
        commandSpec: AppCommandSpec
    ) -> ActionPresentation {
        guard pullRequestFacts?.exactOpenURL != nil else {
            return ActionPresentation(
                accessibilityLabel: commandSpec.label,
                tooltip: commandSpec.controlTooltipRenderValue(),
                icon: commandSpec.icon,
                iconStatusTone: nil
            )
        }
        let readiness = pullRequestFacts?.exactReadiness
        let checkStatus = readiness?.checkStatus ?? .unknown
        let checkDescription: String
        let iconStatusTone: PaneSurfaceToolbarAction.IconStatusTone?
        switch checkStatus {
        case .passed:
            checkDescription = "Checks passed"
            iconStatusTone = .success
        case .running:
            checkDescription = "Checks running"
            iconStatusTone = .warning
        case .failed:
            checkDescription = "Checks failed"
            iconStatusTone = .danger
        case .unknown:
            checkDescription = "Checks unknown"
            iconStatusTone = nil
        }

        var accessibilityDescriptions: [String] = []
        if readiness?.isDraft == true {
            accessibilityDescriptions.append("draft")
        }
        accessibilityDescriptions.append(checkDescription.lowercased())

        let icon: CommandIcon =
            readiness?.isDraft == true
            ? .octicon(.gitPullRequestDraft)
            : commandSpec.icon
        return ActionPresentation(
            accessibilityLabel: ([commandSpec.label] + accessibilityDescriptions)
                .joined(separator: ", "),
            tooltip: commandSpec.controlTooltipRenderValue(
                textOverride: checkDescription
            ),
            icon: icon,
            iconStatusTone: iconStatusTone
        )
    }

    private static func blockerIndicator(
        for readiness: PullRequestReadiness?
    ) -> PaneSurfaceToolbarStatusIndicator? {
        guard let blockerDescription = blockerDescription(for: readiness) else {
            return nil
        }
        return PaneSurfaceToolbarStatusIndicator(
            label: blockerDescription,
            accessibilityIdentifier: "paneSurfaceToolbar.pullRequestBlocker",
            icon: .system(.xmarkCircleFill),
            tooltip: ControlTooltipResolver.resolve(
                .dynamicData(.stateReadout, text: blockerDescription)
            ),
            iconStatusTone: .danger
        )
    }

    private static func blockerDescription(
        for readiness: PullRequestReadiness?
    ) -> String? {
        guard let readiness else { return nil }
        if readiness.mergeState == .dirty || readiness.mergeability == .conflicting {
            return "Merge conflicts"
        }
        switch readiness.reviewStatus {
        case .changesRequested:
            return "Changes requested"
        case .reviewRequired:
            return "Review required"
        case .approved, .unknown:
            break
        }
        if readiness.mergeState == .blocked, readiness.checkStatus == .passed {
            return "Merge blocked"
        }
        return nil
    }
}
