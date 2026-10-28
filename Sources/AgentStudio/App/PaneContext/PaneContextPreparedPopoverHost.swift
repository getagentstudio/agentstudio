import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioRepoExplorer
import AgentStudioSharedComponents
import SwiftUI

/// Renders the materialized value and applies opening-scoped UI effects.
struct PaneContextPreparedPopoverHost: View {
    let paneId: PaneId
    let presentation: PaneContextPopoverEntry
    let location: PaneContextPopoverLocation
    let bindings: PaneContextPopoverHostBindings
    let octiconLoader: OcticonLoader
    let onGoToPane: @MainActor (UUID) -> Void
    var includingDrawers = true
    var onRenderingTaskStarted: @MainActor (Task<Void, Never>) -> Void = { _ in }
    var onConsumerStarted: @MainActor (PaneContextPopoverConsumerHandle) -> Void = { _ in }
    var onConsumerReadCompleted: @MainActor (PaneContextPopoverConsumerHandle) -> Void = { _ in }
    var onApplication: PaneContextPopoverApplicationObserver?
    var onMessageApplication: (@MainActor @Sendable (PaneContextPopoverMessageApplicationEvent) -> Void)?
    var onPresentationEvent: PaneContextPopoverPresentationObserver?
    var onScrollEvent: PaneContextPopoverScrollObserver = { _ in }
    var onNoteApplication: PaneContextNoteApplicationObserver?
    var onDatedLabelApplication: @MainActor (AccessibilityLabelApplication.Event) -> Void = { _ in }
    var onActionCompleted: @MainActor () -> Void = {}
    var onActionTaskStarted: @MainActor (Task<Void, Never>) -> Void = { _ in }
    @State private var hostId = UUIDv7.generate()
    @State private var anchor = PaneContextPopoverAnchor.Reference()
    @State private var handle: PaneContextPopoverConsumerHandle?
    @State private var requestedKey: PaneContextPopoverConsumerKey?
    @State private var renderingTask: Task<Void, Never>?
    @State private var closingTask: Task<Void, Never>?
    @State private var isPresented = false
    @State private var mounted = false
    @State private var openRequest: UInt64 = 0
    @State private var readback: PaneContextPopoverOpeningReadback?
    @State private var preparedPublication: UUID?

    private struct ScrollIdentity: Equatable {
        let opening: UInt64
        let publication: UUID?
    }
    private var key: PaneContextPopoverConsumerKey {
        let surface: PaneContextPopoverConsumerKey.Surface
        if case .agentLine = presentation {
            surface = .agentLine
        } else {
            surface =
                switch location {
                case .sidebar: .sidebarMessages
                case .pane: .paneMessages
                case .card: .cardMessages
                }
        }
        return .init(hostId: hostId, surface: surface, paneId: paneId)
    }

    var body: some View {
        button
            .background { PaneContextPopoverAnchor(reference: anchor) }
            .popover(isPresented: $isPresented, arrowEdge: .bottom) { popover }
            .onAppear { mounted = true }
            .onChange(of: key) { _, changed in
                retireReadback()
                if let requestedKey, requestedKey != changed {
                    isPresented = false
                    close()
                }
            }
            .onChange(of: isPresented) { _, shown in
                if !shown, !isPresented, handle != nil { close() }
            }
            .onChange(of: handle?.atom.value?.publication.id) { _, _ in
                guard isPresented, let value = handle?.atom.value else { return }
                if case .paneGone = value.content.body {
                    isPresented = false
                    return
                }
                notifyPrepared(value)
            }
            .onDisappear {
                mounted = false
                isPresented = false
                retireReadback()
                close()
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
                    identifier: "pane-context.agent-line", label: LocalActionSpec.showPaneAgentLine.actionSpec.label,
                    help: line.tooltip.text, action: requestOpen)
            }
        }
    }

    @ViewBuilder private var popover: some View {
        if let handle, let value = handle.atom.value {
            switch value.content.body {
            case .messages(let model, let target):
                ScrollViewReader { proxy in
                    MessagesPopover(
                        paneId: paneId.uuid, model: model, controls: PaneContextPopoverControlProjection.controls(),
                        octiconLoader: octiconLoader, location: location, feedback: value.content.feedback,
                        width: value.content.width,
                        actions: PaneContextPopoverHostActions.messages(
                            handle: handle, bindings: bindings,
                            isCurrentOpening: { self.handle?.opening.epoch == handle.opening.epoch && isPresented },
                            onGoToPane: goToPaneAndDismiss, onDismissPopover: { isPresented = false },
                            onActionCompleted: onActionCompleted, onActionTaskStarted: onActionTaskStarted,
                            presentationObservation: presentationObservation),
                        messageApplication: messageApplication(value)
                    )
                    .task(id: scrollIdentity(handle, value: value)) {
                        await PaneContextPopoverScrollObservation.perform(
                            requested: presentation.messagesTarget, effective: target,
                            isPresented: { isPresented && mounted },
                            observe: onScrollEvent,
                            apply: { operation in
                                switch target {
                                case .top:
                                    proxy.scrollTo(
                                        PaneContextPopoverScrollObservation.target(
                                            PaneContextPopoverPanelAnchor.top, operation: operation,
                                            observe: onScrollEvent), anchor: .top)
                                case .section(let kind):
                                    proxy.scrollTo(
                                        PaneContextPopoverScrollObservation.target(
                                            kind, operation: operation, observe: onScrollEvent), anchor: .top)
                                case .message(let key):
                                    proxy.scrollTo(
                                        PaneContextPopoverScrollObservation.target(
                                            MessageRowModel.Key(
                                                sourcePaneId: key.paneId.uuid, messageId: key.messageId.uuid),
                                            operation: operation, observe: onScrollEvent), anchor: .top)
                                }
                            })
                    }
                }
                .background { applicationView(value) }
            case .agentLine(let line):
                if let line {
                    AgentLinePopover(
                        model: line, octiconLoader: octiconLoader,
                        goToPaneControl: PaneContextPopoverControlProjection.controls().goToPane,
                        feedback: value.content.feedback, labelApplication: datedApplication(value)
                    ) {
                        goToPaneAndDismiss(paneId.uuid)
                    }
                }
            case .note(let text): note(text, width: value.content.width)
            case .paneGone: EmptyView()
            case .card, .toolbar: EmptyView()
            }
        } else {
            note(
                "Loading…",
                width: handle?.opening.loadingWidth ?? AppStyles.Components.PaneContext.messagesPopoverIdealWidth)
        }
    }

    private func requestOpen() {
        let nextKey = key
        if let requestedKey, requestedKey != nextKey {
            isPresented = false
            close()
        }
        requestedKey = nextKey
        openRequest &+= 1
        let requested = openRequest
        renderingTask?.cancel()
        installReadback()
        let content: PaneContextPopoverDemand.Content
        if case .agentLine = presentation {
            content = .agentLine
        } else {
            content = .messages(presentation.messagesTarget)
        }
        let setup = bindings.beginOpen(
            nextKey,
            demand: .init(
                content: content, location: location,
                includingDrawers: includingDrawers, screenVisibleWidth: anchor.screenVisibleWidth))
        let task = Task { @MainActor in
            guard let next = await setup.value else { return }
            guard !Task.isCancelled, mounted, openRequest == requested else {
                await abandon(next, requested: requested)
                return
            }
            handle = next
            isPresented = true
            onConsumerStarted(next)
            await next.opening.initialExecution.task.value
            guard !Task.isCancelled, mounted, self.handle?.opening.epoch == next.opening.epoch else {
                await abandon(next, requested: requested)
                return
            }
            onConsumerReadCompleted(next)
            if let value = next.atom.value { notifyPrepared(value) }
        }
        renderingTask = task
        onRenderingTaskStarted(task)
    }

    private func abandon(_ abandoned: PaneContextPopoverConsumerHandle, requested: UInt64) async {
        if openRequest == requested {
            isPresented = false
            close()
            let closing = closingTask
            await closing?.value
        } else {
            // A newer opening owns the host key; retire only the abandoned epoch.
            await bindings.retire(abandoned)
        }
    }

    private func close() {
        let closingKey = requestedKey ?? handle?.key
        requestedKey = nil
        renderingTask?.cancel()
        renderingTask = nil
        handle = nil
        if let closingKey { closingTask = bindings.beginClose(closingKey) }
    }

    private func retireReadback() {
        readback?.retire()
        readback = nil
    }

    private func scrollIdentity(_ handle: PaneContextPopoverConsumerHandle, value: PopoverDetail) -> ScrollIdentity {
        if case .message = presentation.messagesTarget {
            return .init(opening: handle.opening.epoch, publication: value.messageScrollToken)
        }
        return .init(opening: handle.opening.epoch, publication: nil)
    }

    private func notifyPrepared(_ value: PopoverDetail) {
        guard preparedPublication != value.publication.id, let application = application(value) else { return }
        preparedPublication = value.publication.id
        onApplication?(.prepared(application))
    }

    private func application(_ value: PopoverDetail) -> PaneContextPopoverApplication? {
        guard onApplication != nil, let shape = value.shape else { return nil }
        return .init(publication: value.publication, value: .popover(shape), feedback: value.content.feedback)
    }
    @ViewBuilder private func applicationView(_ value: PopoverDetail) -> some View {
        if let application = application(value), let onApplication {
            NativePresentationApplication(
                value: application,
                onApplied: { onApplication(.applied($0)) }, onRetired: { onApplication(.retired($0)) })
        }
    }
    private func messageApplication(_ value: PopoverDetail) -> PaneContextMessageTextApplication? {
        guard let onMessageApplication else { return nil }
        return .init(key: .init(producerId: value.publication.producer.id, valueId: value.publication.id)) { event in
            onMessageApplication(.init(publication: value.publication, event: event))
        }
    }

    private func datedApplication(_ value: PopoverDetail) -> AccessibilityLabelApplication? {
        guard let application = application(value), let onApplication else { return nil }
        let key = AccessibilityLabelApplication.Key(
            producerId: application.publication.producer.id, valueId: application.publication.id)
        return .init(key: key) { event in
            switch event {
            case .applied: onApplication(.applied(application))
            case .retired: onApplication(.retired(application))
            case .updateEnded: break
            }
            onDatedLabelApplication(event)
        }
    }
    private var presentationObservation: PaneContextPopoverPresentationObservation? {
        onPresentationEvent.map { .init(isPresented: { isPresented }, observe: $0) }
    }
    private func goToPaneAndDismiss(_ target: UUID) {
        let operation = presentationObservation?.operation()
        operation?.started(.synchronous)
        onGoToPane(target)
        isPresented = false
        operation?.decided()
    }
    private func installReadback() {
        guard let onPresentationEvent else { return }
        readback?.retire()
        let current = PaneContextPopoverOpeningReadback(ownerIdentity: ObjectIdentifier(anchor), opening: openRequest) {
            .init(
                isPresented: isPresented, paneId: handle?.key.paneId,
                controllerIdentity: handle.map { ObjectIdentifier($0.atom) }, openRequest: openRequest)
        }
        readback = current
        onPresentationEvent(.opened(current))
    }
    private func note(_ text: String, width: Double) -> some View {
        let value = PaneContextNoteApplication.Value(
            paneId: paneId, location: location, openRequest: openRequest, text: text)
        return PopoverPanel { PaneContextPopoverNote(text) }
            .frame(width: width)
            .background { AccessibilityLabelBridge(identifier: "pane-context.popover-panel", label: "", role: .group) }
            .background {
                if let onNoteApplication {
                    NativePresentationApplication(
                        value: value,
                        onApplied: { onNoteApplication(.applied($0)) }, onRetired: { onNoteApplication(.retired($0)) })
                }
            }
    }
}
