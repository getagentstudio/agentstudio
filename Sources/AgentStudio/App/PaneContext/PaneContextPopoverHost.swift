import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioRepoExplorer
import AgentStudioSharedComponents
import SwiftUI

/// Local presentation state; providers resolve effects only when the person opens or acts.
struct PaneContextPopoverHost<AgeClock: Clock>: View
where AgeClock.Duration == Duration, AgeClock.Instant == ContinuousClock.Instant {
    let paneId: PaneId
    let presentation: PaneContextPopoverEntry
    let location: PaneContextPopoverLocation
    let readers: PaneContextUIReaders
    let octiconLoader: OcticonLoader
    let onGoToPane: @MainActor (UUID) -> Void
    let includingDrawers: Bool
    let onReadCompleted: PaneContextReadCompletionObserver
    let onReadTaskStarted: PaneContextReadTaskObserver
    let onActionCompleted: @MainActor () -> Void
    let onActionTaskStarted: @MainActor (Task<Void, Never>) -> Void
    let clock: AgeClock
    let wallNow: @Sendable () -> Date
    @State private var controller: PaneContextPopoverController?
    @State private var isPresented = false
    @State private var unavailableNote: String?
    @State private var relativeTimeRefresh: PaneRelativeTimeRefresh
    @State private var openRequest: UInt64 = 0
    private var controls: PaneContextPopoverControls { PaneContextPopoverControlProjection.controls() }

    init(
        paneId: PaneId, presentation: PaneContextPopoverEntry,
        location: PaneContextPopoverLocation, readers: PaneContextUIReaders, octiconLoader: OcticonLoader,
        onGoToPane: @escaping @MainActor (UUID) -> Void, includingDrawers: Bool = true,
        onReadCompleted: @escaping PaneContextReadCompletionObserver = { _, _ in
        },
        onReadTaskStarted: @escaping PaneContextReadTaskObserver = { _, _ in },
        onActionCompleted: @escaping @MainActor () -> Void = {},
        onActionTaskStarted: @escaping @MainActor (Task<Void, Never>) -> Void = { _ in },
        clock: AgeClock, wallNow: @escaping @Sendable () -> Date = Date.init,
        onRelativeTimeEvent: @escaping @MainActor @Sendable (PaneRelativeTimeRefresh.Event) -> Void = { _ in }
    ) {
        self.paneId = paneId
        self.presentation = presentation
        self.location = location
        self.readers = readers
        self.octiconLoader = octiconLoader
        self.onGoToPane = onGoToPane
        self.includingDrawers = includingDrawers
        self.onReadCompleted = onReadCompleted
        self.onReadTaskStarted = onReadTaskStarted
        self.onActionCompleted = onActionCompleted
        self.onActionTaskStarted = onActionTaskStarted
        self.clock = clock
        self.wallNow = wallNow
        _relativeTimeRefresh = State(initialValue: PaneRelativeTimeRefresh(onEvent: onRelativeTimeEvent))
    }

    var body: some View {
        button
            .popover(isPresented: $isPresented, arrowEdge: .bottom) { popover }
            .task(id: openRequest) {
                guard openRequest > 0 else { return }
                await PaneContextPopoverHostActions.read(
                    key: readers.refreshKey(for: paneId), location: location, onStarted: onReadTaskStarted
                ) { read in
                    await openPopover(read: read)
                }
            }
            .task(id: readers.refreshKey(for: paneId)) {
                guard isPresented, let controller, controller.needsRevisionRefresh else { return }
                let key = readers.refreshKey(for: paneId)
                await PaneContextPopoverHostActions.read(
                    key: key, location: location, onStarted: onReadTaskStarted
                ) { read in
                    guard controller.useCurrentService(readers.serviceProvider()) else {
                        onReadCompleted(read, controller)
                        return
                    }
                    if await controller.refreshIfRevisionChanged(), !Task.isCancelled {
                        onReadCompleted(read, controller)
                    }
                }
            }
            .onChange(of: controller?.paneId) { _, pane in
                if pane == nil, unavailableNote == nil, controller?.unavailableNote == nil { isPresented = false }
            }
            .onChange(of: isPresented) { _, presented in
                if !presented { controller?.close() }
            }
            .onChange(of: controller?.state) { _, state in refreshAges(state) }
            .onDisappear {
                controller?.close()
                relativeTimeRefresh.hide()
            }
    }

    @ViewBuilder private var button: some View {
        switch presentation {
        case .messagesAction(let control, _):
            PaneContextActionButton(control, action: requestOpen)
        case .kind(let chip):
            PaneMessageKindChip(
                model: chip, control: RepoExplorerPaneKindChipProjection.control(chip),
                octiconLoader: octiconLoader, onOpen: requestOpen)
        case .agentLine(let line):
            Button(action: requestOpen) {
                RepoExplorerPaneContextLineView(line: line, isAgentLine: true, octiconLoader: octiconLoader)
            }
            .buttonStyle(.plain)
            .accessibilityHidden(true)
            .background {
                AccessibilityPressBridge(
                    identifier: "pane-context.agent-line",
                    label: LocalActionSpec.showPaneAgentLine.actionSpec.label, help: line.tooltip.text,
                    action: requestOpen)
            }
        }
    }
    @ViewBuilder private var popover: some View {
        if let unavailableNote {
            note(unavailableNote)
        } else if let controller, let state = controller.state {
            let visible = relativeTimeRefresh.popoverShape.flatMap { $0.revision == state.revision ? $0 : nil } ?? state
            switch presentation {
            case .kind, .messagesAction:
                ScrollViewReader { proxy in
                    MessagesPopover(
                        paneId: paneId.uuid, model: visible.messages, controls: controls, octiconLoader: octiconLoader,
                        location: location,
                        feedback: controller.unavailableNote ?? controller.actionFeedback,
                        actions: PaneContextPopoverHostActions.messages(
                            controller: controller, readers: readers, onGoToPane: onGoToPane,
                            onActionCompleted: onActionCompleted, onActionTaskStarted: onActionTaskStarted)
                    )
                    .task(id: visible.messages) {
                        if case .messagesAction(_, let key?) = presentation {
                            proxy.scrollTo(
                                MessageRowModel.Key(
                                    sourcePaneId: key.paneId.uuid,
                                    messageId: key.messageId.uuid), anchor: .top)
                        }
                    }
                }
            case .agentLine:
                if let line = visible.agentLine {
                    AgentLinePopover(
                        model: line, goToPaneControl: controls.goToPane, feedback: controller.unavailableNote
                    ) {
                        onGoToPane(paneId.uuid)
                    }
                }
            }
        } else if let note = controller?.unavailableNote {
            self.note(note)
        } else {
            note("Loading…")
        }
    }
    private func requestOpen() {
        isPresented = true
        openRequest &+= 1
    }
    private func openPopover(read: PaneContextReadOperation) async {
        isPresented = true
        unavailableNote = nil
        guard let adapter = readers.serviceProvider() else {
            controller?.close()
            controller = nil
            unavailableNote = "Not available right now"
            onReadCompleted(read, nil)
            return
        }
        let active =
            controller
            ?? readers.makePopoverController(
                reader: adapter, person: adapter,
                location: location, includingDrawers: includingDrawers, wallNow: wallNow)
        controller = active
        _ = active.useCurrentService(adapter)
        if case .messagesAction(_, let key) = presentation {
            await active.openMessages(paneId, focusedMessage: key)
        } else {
            await active.open(paneId)
        }
        guard !Task.isCancelled else { return }
        onReadCompleted(read, active)
    }

    private func refreshAges(_ shape: PaneContextPopoverShape?) {
        guard isPresented, let shape else {
            relativeTimeRefresh.hide()
            return
        }
        let content: PaneManagementIdentityCapture.PopoverContent =
            switch presentation {
            case .kind, .messagesAction: .messages
            case .agentLine: .agentLine
            }
        relativeTimeRefresh.startOrReplace(.popover(shape, content), clock: clock, wallNow: wallNow())
    }
    private func note(_ text: String) -> some View {
        PopoverPanel { PaneContextPopoverNote(text) }
            .frame(width: AppStyles.Components.PaneContext.popoverWidth)
            .background {
                AccessibilityLabelBridge(identifier: "pane-context.popover-panel", label: "", role: .group)
            }
    }
}

extension PaneContextPopoverHost where AgeClock == ContinuousClock {
    init(
        paneId: PaneId, presentation: PaneContextPopoverEntry,
        location: PaneContextPopoverLocation, readers: PaneContextUIReaders, octiconLoader: OcticonLoader,
        onGoToPane: @escaping @MainActor (UUID) -> Void, includingDrawers: Bool = true,
        onReadCompleted: @escaping PaneContextReadCompletionObserver = { _, _ in
        },
        onActionCompleted: @escaping @MainActor () -> Void = {},
        onActionTaskStarted: @escaping @MainActor (Task<Void, Never>) -> Void = { _ in }
    ) {
        self.init(
            paneId: paneId, presentation: presentation, location: location, readers: readers,
            octiconLoader: octiconLoader, onGoToPane: onGoToPane, includingDrawers: includingDrawers,
            onReadCompleted: onReadCompleted, onActionCompleted: onActionCompleted,
            onActionTaskStarted: onActionTaskStarted, clock: ContinuousClock())
    }
}
