import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioRepoExplorer
import AgentStudioSharedComponents
import SwiftUI

enum PaneContextNoteApplication: Equatable, Sendable {
    struct Value: Equatable, Sendable {
        let paneId: PaneId
        let location: PaneContextPopoverLocation
        let openRequest: UInt64
        let text: String
    }
    case applied(Value)
    case retired(Value)
}
typealias PaneContextNoteApplicationObserver = @MainActor (PaneContextNoteApplication) -> Void

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
    let onPresentationEvent: PaneContextPopoverPresentationObserver?
    let onScrollEvent: PaneContextPopoverScrollObserver
    let onNoteApplication: PaneContextNoteApplicationObserver
    let onDatedLabelApplication: @MainActor (AccessibilityLabelApplication.Event) -> Void
    let onActionCompleted: @MainActor () -> Void
    let onActionTaskStarted: @MainActor (Task<Void, Never>) -> Void
    let clock: AgeClock
    let wallNow: @Sendable () -> Date
    @State private var openingAnchor = PaneContextPopoverAnchor.Reference()
    @State private var messagesWidth = MessagesPopoverWidthState.loading(
        AppStyles.Components.PaneContext.messagesPopoverIdealWidth)
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
        onPresentationEvent: PaneContextPopoverPresentationObserver? = nil,
        onScrollEvent: @escaping PaneContextPopoverScrollObserver = { _ in },
        onNoteApplication: @escaping PaneContextNoteApplicationObserver = { _ in },
        onDatedLabelApplication: @escaping @MainActor (AccessibilityLabelApplication.Event) -> Void = { _ in },
        onActionCompleted: @escaping @MainActor () -> Void = {},
        onActionTaskStarted: @escaping @MainActor (Task<Void, Never>) -> Void = { _ in },
        clock: AgeClock, wallNow: @escaping @Sendable () -> Date = Date.init,
        onRelativeTimeEvent: @escaping @MainActor @Sendable (PaneRelativeTimeRefresh.Event) -> Void = { _ in },
        onRelativeTimeReady: @escaping PaneRelativeTimeRefresh.PresentationReadyObserver = { _, _ in }
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
        self.onPresentationEvent = onPresentationEvent
        self.onScrollEvent = onScrollEvent
        self.onNoteApplication = onNoteApplication
        self.onDatedLabelApplication = onDatedLabelApplication
        self.onActionCompleted = onActionCompleted
        self.onActionTaskStarted = onActionTaskStarted
        self.clock = clock
        self.wallNow = wallNow
        _relativeTimeRefresh = State(
            initialValue: PaneRelativeTimeRefresh(
                onEvent: onRelativeTimeEvent, onPresentationReady: onRelativeTimeReady))
    }

    var body: some View {
        button
            .background { PaneContextPopoverAnchor(reference: openingAnchor) }
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
                    _ = await controller.refreshIfRevisionChanged()
                    guard !Task.isCancelled else { return }
                    onReadCompleted(read, controller)
                }
            }
            .onChange(of: controller?.paneId) { _, pane in
                if pane == nil, unavailableNote == nil, controller?.unavailableNote == nil { isPresented = false }
            }
            .onChange(of: isPresented) { _, presented in
                if !presented { controller?.close() }
            }
            .onChange(of: controller?.state) { _, state in
                if let state { selectContentWidth(state.messages) }
                refreshAges(state)
            }
            .onDisappear {
                controller?.close()
                relativeTimeRefresh.hide()
            }
    }

    @ViewBuilder private var button: some View {
        switch presentation {
        case .messagesAction(let control, _):
            PaneContextActionButton(control, role: .utility(octiconLoader), action: requestOpen)
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
                if case .loading = messagesWidth {
                    note("Loading…")
                } else {
                    ScrollViewReader { proxy in
                        MessagesPopover(
                            paneId: paneId.uuid, model: visible.messages, controls: controls,
                            octiconLoader: octiconLoader,
                            location: location,
                            feedback: controller.unavailableNote ?? controller.actionFeedback,
                            width: messagesWidth.width,
                            actions: PaneContextPopoverHostActions.messages(
                                controller: controller, readers: readers, onGoToPane: goToPaneAndDismissPopover,
                                onDismissPopover: dismissPopover,
                                onActionCompleted: onActionCompleted, onActionTaskStarted: onActionTaskStarted,
                                presentationObservation: presentationObservation)
                        )
                        .task(
                            id: presentation.messagesScrollTrigger(openRequest: openRequest, messages: visible.messages)
                        ) {
                            await PaneContextPopoverScrollObservation.perform(
                                requested: presentation.messagesTarget, effective: visible.messagesTarget,
                                isPresented: { isPresented && controller.paneId != nil }, observe: onScrollEvent,
                                apply: { operation in
                                    switch visible.messagesTarget {
                                    case .top:
                                        proxy.scrollTo(
                                            PaneContextPopoverScrollObservation.target(
                                                PaneContextPopoverPanelAnchor.top, operation: operation,
                                                observe: onScrollEvent),
                                            anchor: .top)
                                    case .section(let kind):
                                        proxy.scrollTo(
                                            PaneContextPopoverScrollObservation.target(
                                                kind, operation: operation, observe: onScrollEvent),
                                            anchor: .top)
                                    case .message(let key):
                                        proxy.scrollTo(
                                            PaneContextPopoverScrollObservation.target(
                                                MessageRowModel.Key(
                                                    sourcePaneId: key.paneId.uuid, messageId: key.messageId.uuid),
                                                operation: operation, observe: onScrollEvent),
                                            anchor: .top)
                                    }
                                })
                        }
                    }
                    .background { applicationReceipt(for: .popover(visible)) }
                }
            case .agentLine:
                if let line = visible.agentLine {
                    AgentLinePopover(
                        model: line, octiconLoader: octiconLoader, goToPaneControl: controls.goToPane,
                        feedback: controller.unavailableNote,
                        labelApplication: datedLabelApplication(for: .popover(visible))
                    ) {
                        goToPaneAndDismissPopover(paneId.uuid)
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
        messagesWidth = .loading(screenVisibleWidth: openingAnchor.screenVisibleWidth)
        isPresented = true
        openRequest &+= 1
    }
    @ViewBuilder private func applicationReceipt(for value: PaneManagementIdentityCapture.VisiblePresentation)
        -> some View
    {
        if let application = relativeTimeRefresh.application(
            for: value, feedback: controller?.unavailableNote ?? controller?.actionFeedback)
        {
            NativePresentationApplication(
                value: application, onApplied: relativeTimeRefresh.didApply,
                onRetired: relativeTimeRefresh.didRetire)
        }
    }
    private func datedLabelApplication(for value: PaneManagementIdentityCapture.VisiblePresentation)
        -> AccessibilityLabelApplication?
    {
        guard
            let application = relativeTimeRefresh.application(
                for: value, feedback: controller?.unavailableNote ?? controller?.actionFeedback)
        else { return nil }
        return .init(key: .init(producerId: application.operationId, valueId: application.applicationId)) { event in
            switch event {
            case .applied: relativeTimeRefresh.didApply(application)
            case .retired: relativeTimeRefresh.didRetire(application)
            case .updateEnded: break
            }
            onDatedLabelApplication(event)
        }
    }

    private var presentationObservation: PaneContextPopoverPresentationObservation? {
        onPresentationEvent.map { .init(isPresented: { isPresented }, observe: $0) }
    }
    private func goToPaneAndDismissPopover(_ targetPaneId: UUID) {
        let operation = presentationObservation?.operation()
        operation?.started(.synchronous)
        onGoToPane(targetPaneId)
        dismissPopover()
        operation?.decided()
    }
    private func dismissPopover() {
        isPresented = false
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
        switch presentation {
        case .kind, .messagesAction: await active.openMessages(paneId, target: presentation.messagesTarget)
        case .agentLine: await active.open(paneId)
        }
        guard !Task.isCancelled else { return }
        if let state = active.state { selectContentWidth(state.messages) }
        onReadCompleted(read, active)
    }

    private func selectContentWidth(_ model: MessagesPopoverModel) {
        guard case .loading = messagesWidth else { return }
        messagesWidth = messagesWidth.receivingContent(
            hasMultilineBody: MessagesPopoverWidthState.hasMultilineBody(in: model),
            screenVisibleWidth: openingAnchor.screenVisibleWidth)
    }

    private var noteWidth: CGFloat {
        switch presentation {
        case .agentLine: AppStyles.Components.PaneContext.popoverWidth
        case .kind, .messagesAction: messagesWidth.width
        }
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
        let application = PaneContextNoteApplication.Value(
            paneId: paneId, location: location, openRequest: openRequest, text: text)
        return PopoverPanel { PaneContextPopoverNote(text) }
            .frame(width: noteWidth)
            .background {
                AccessibilityLabelBridge(identifier: "pane-context.popover-panel", label: "", role: .group)
            }
            .background {
                NativePresentationApplication(
                    value: application,
                    onApplied: { onNoteApplication(.applied($0)) },
                    onRetired: { onNoteApplication(.retired($0)) })
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
        onPresentationEvent: PaneContextPopoverPresentationObserver? = nil,
        onNoteApplication: @escaping PaneContextNoteApplicationObserver = { _ in },
        onActionCompleted: @escaping @MainActor () -> Void = {},
        onActionTaskStarted: @escaping @MainActor (Task<Void, Never>) -> Void = { _ in }
    ) {
        self.init(
            paneId: paneId, presentation: presentation, location: location, readers: readers,
            octiconLoader: octiconLoader, onGoToPane: onGoToPane, includingDrawers: includingDrawers,
            onReadCompleted: onReadCompleted, onPresentationEvent: onPresentationEvent,
            onNoteApplication: onNoteApplication,
            onActionCompleted: onActionCompleted,
            onActionTaskStarted: onActionTaskStarted, clock: ContinuousClock())
    }
}
