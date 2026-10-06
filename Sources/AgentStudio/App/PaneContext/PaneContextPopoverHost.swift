import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioRepoExplorer
import AgentStudioSharedComponents
import SwiftUI

/// Local presentation state; providers resolve effects only when the person opens or acts.
struct PaneContextPopoverHost: View {
    struct AutoOpenInput: Equatable {
        let ask: AgentMessageId?
        let visible: Bool
    }
    let paneId: PaneId
    let presentation: RepoExplorerPaneContextControlPresentation
    let location: PaneContextPopoverLocation
    let readers: PaneContextUIReaders
    let octiconLoader: OcticonLoader
    let onGoToPane: @MainActor (UUID) -> Void
    var autoOpenAskId: AgentMessageId?
    var isHostVisible = true
    var onOpenCompleted: @MainActor (PaneContextPopoverController?) -> Void = { _ in }
    @State private var controller: PaneContextPopoverController?
    @State private var isPresented = false
    @State private var unavailableNote: String?
    @State private var includeInformational = false
    @Environment(\.paneContextPopoverAutoOpenState) private var autoOpenState
    @State private var openRequest: UInt64 = 0
    private static let controls = PaneContextPopoverControlProjection.controls()

    static func shouldPresentMessagesButton(chip: PaneMessageChipModel) -> Bool {
        chip.tone != .neutral || chip.countIncludingInformational != chip.count
    }

    var body: some View {
        button
            .popover(isPresented: $isPresented, arrowEdge: .bottom) { popover }
            .task(id: openRequest) {
                guard openRequest > 0 else { return }
                await openPopover()
            }
            .task(id: AutoOpenInput(ask: autoOpenAskId, visible: isHostVisible)) {
                guard
                    let askId = autoOpenAskId,
                    let autoOpenState,
                    PaneContextPopoverAutoOpenPolicy.shouldOpen(
                        newestAskId: askId,
                        lastPresentedAskId: autoOpenState.lastPresentedAskId(for: paneId),
                        isVisible: isHostVisible, location: location)
                else { return }
                autoOpenState.rememberPresentedAsk(askId, for: paneId)
                await openPopover()
            }
            .task(id: readers.contextDisplayForPane(paneId)?.revision) {
                guard isPresented, let controller else { return }
                guard controller.useCurrentService(readers.serviceProvider()) else { return }
                await controller.refreshIfRevisionChanged()
            }
            .onChange(of: controller?.paneId) { _, pane in
                if pane == nil, unavailableNote == nil, controller?.unavailableNote == nil { isPresented = false }
            }
            .onChange(of: isPresented) { _, presented in
                if !presented { controller?.close() }
            }
            .onChange(of: isHostVisible) { _, visible in
                if !visible { isPresented = false }
            }
            .onDisappear { controller?.close() }
    }

    @ViewBuilder private var button: some View {
        switch presentation {
        case .messages(let chip):
            let count = includeInformational ? chip.countIncludingInformational : chip.count
            if Self.shouldPresentMessagesButton(chip: chip) {
                MessagesChip(
                    count: count, tone: includeInformational ? chip.toneIncludingInformational : chip.tone,
                    control: Self.controls.messages, octiconLoader: octiconLoader, onOpen: requestOpen)
            }
        case .pullRequests(let chip):
            GitPRSummaryChip(
                presentation: chip.presentation, control: chip.control, octiconLoader: octiconLoader,
                onOpen: requestOpen)
        case .agentLine(let line):
            Button(action: requestOpen) {
                RepoExplorerPaneContextLineView(line: line, isAgentLine: true, octiconLoader: octiconLoader)
            }
            .buttonStyle(.plain)
            .accessibilityHidden(true)
            .background {
                AccessibilityPressBridge(
                    identifier: "pane-context.agent-line",
                    label: LocalActionSpec.showPaneAgentLine(.done).actionSpec.label, help: line.tooltip.text,
                    action: requestOpen)
            }
        }
    }
    @ViewBuilder private var popover: some View {
        if let unavailableNote {
            PopoverPanel { Text(unavailableNote).foregroundStyle(.secondary) }
        } else if let controller, let state = controller.state {
            switch presentation {
            case .messages:
                MessagesPopover(
                    paneId: paneId.uuid, model: state.messages, controls: Self.controls, location: location,
                    providerPrompts: state.providerPrompts, feedback: controller.actionFeedback,
                    informationalToggle: PaneContextPopoverControlProjection.control(
                        .countInformationalPaneMessages, identifier: "pane-context.count-informational"),
                    includesInformational: $includeInformational,
                    actions: PaneContextPopoverHostActions.messages(
                        controller: controller, readers: readers, onGoToPane: onGoToPane))
                if let note = controller.unavailableNote { Text(note).foregroundStyle(.secondary) }
            case .pullRequests:
                if let chip = state.pullRequestSummaryChip {
                    GitPRSummaryPopover(
                        model: chip.model, presentation: chip.presentation, controls: Self.controls,
                        onGoToPane: { onGoToPane(paneId.uuid) })
                } else {
                    PopoverPanel { Text(LocalActionSpec.panePullRequestSummaryStatus(.noInfo).actionSpec.label) }
                }
                if let note = controller.unavailableNote { Text(note).foregroundStyle(.secondary) }
            case .agentLine:
                if let line = state.agentLine {
                    AgentLinePopover(
                        model: line, providerPrompts: state.providerPrompts, goToPaneControl: Self.controls.goToPane
                    ) {
                        onGoToPane(paneId.uuid)
                    }
                }
                if let note = controller.unavailableNote { Text(note).foregroundStyle(.secondary) }
            }
        } else if let note = controller?.unavailableNote {
            PopoverPanel { Text(note).foregroundStyle(.secondary) }
        } else {
            PopoverPanel { Text("Loading…").foregroundStyle(.secondary) }
        }
    }
    private func requestOpen() {
        isPresented = true
        openRequest &+= 1
    }
    private func openPopover() async {
        isPresented = true
        unavailableNote = nil
        guard let adapter = readers.serviceProvider() else {
            controller?.close()
            controller = nil
            unavailableNote = "Not available right now"
            onOpenCompleted(nil)
            return
        }
        let active =
            controller
            ?? readers.makePopoverController(
                reader: adapter, person: adapter,
                location: location)
        controller = active
        _ = active.useCurrentService(adapter)
        await active.open(paneId)
        guard !Task.isCancelled else { return }
        onOpenCompleted(active)
    }
}
