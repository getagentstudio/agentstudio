import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSharedComponents
import SwiftUI

/// The existing parent context remains an input; card detail comes from the prepared family value.
struct PaneContextPreparedManagementOverlay: View {
    let context: PaneManagementContext
    let octiconLoader: OcticonLoader
    let readers: PaneContextUIReaders
    let bindings: PaneContextPopoverHostBindings
    let onGoToPane: @MainActor (UUID) -> Void
    var onRenderingTaskStarted: @MainActor (Task<Void, Never>) -> Void = { _ in }
    var onConsumerStarted: @MainActor (PaneContextPopoverConsumerHandle) -> Void = { _ in }
    var onConsumerReadCompleted: @MainActor (PaneContextPopoverConsumerHandle) -> Void = { _ in }
    var onApplication: PaneContextPopoverApplicationObserver?
    var onMessageApplication: (@MainActor @Sendable (PaneContextPopoverMessageApplicationEvent) -> Void)?
    var onPresentationEvent: PaneContextPopoverPresentationObserver?
    var onScrollEvent: PaneContextPopoverScrollObserver = { _ in }
    var onNoteApplication: PaneContextNoteApplicationObserver?
    var onActionCompleted: @MainActor () -> Void = {}
    var onActionTaskStarted: @MainActor (Task<Void, Never>) -> Void = { _ in }
    @State private var hostId = UUIDv7.generate()
    @State private var handle: PaneContextPopoverConsumerHandle?
    @State private var requestedKey: PaneContextPopoverConsumerKey?
    @State private var setupTask: Task<Void, Never>?
    @State private var closeTask: Task<Void, Never>?
    @State private var mounted = false
    @State private var preparedPublication: UUID?
    @State var messageInteractions = PaneContextPopoverInteractionState()

    private var key: PaneContextPopoverConsumerKey {
        .init(hostId: hostId, surface: .managementCard, paneId: .init(existingUUID: context.paneId))
    }
    var body: some View {
        let value = handle?.atom.value
        let card = value?.card
        let actions = handle.map { handle in
            PaneContextPopoverHostActions.messages(
                handle: handle, bindings: bindings,
                isCurrentOpening: { self.handle?.opening.epoch == handle.opening.epoch && mounted },
                onGoToPane: onGoToPane, onActionCompleted: onActionCompleted, onActionTaskStarted: onActionTaskStarted,
                interactionState: messageInteractions)
        }
        ManagementPaneIdentityStrip(
            context: context.includingVerifiedLiveSession(value?.liveSession), octiconLoader: octiconLoader,
            lines: card?.information.lines ?? [], isDrawerPane: value?.isDrawer ?? false,
            activityText: card?.activityText, unreadCount: card?.unreadCount ?? 0,
            cardModel: card, readers: readers, actions: actions, feedback: value?.content.feedback,
            interactions: handle.flatMap { handle in
                value.map { value in
                    messageInteractions.bindings(
                        versions: value.interactions.versions, opening: handle.opening.epoch,
                        currentVersions: { self.handle?.atom.latestAcceptedValue?.interactions.versions })
                }
            },
            onGoToPane: onGoToPane, onRenderingTaskStarted: onRenderingTaskStarted,
            onConsumerStarted: onConsumerStarted, onConsumerReadCompleted: onConsumerReadCompleted,
            onApplication: onApplication, onMessageApplication: onMessageApplication,
            onPresentationEvent: onPresentationEvent, onScrollEvent: onScrollEvent,
            onNoteApplication: onNoteApplication,
            onActionCompleted: onActionCompleted, onActionTaskStarted: onActionTaskStarted
        )
        .frame(maxWidth: .infinity)
        .background(AppStyles.Shell.PaneChrome.background)
        .background {
            if let value, let card, let onApplication {
                let application = PaneContextPopoverApplication(
                    publication: value.publication, value: .card(card), feedback: value.content.feedback)
                NativePresentationApplication(
                    value: application,
                    onApplied: { onApplication(.applied($0)) }, onRetired: { onApplication(.retired($0)) })
            }
        }
        .onChange(of: value?.publication.id) { _, _ in
            if let value { notifyPrepared(value) }
        }
        .onAppear {
            mounted = true
            startDemand()
        }
        .onChange(of: key) { _, changed in
            if mounted, requestedKey != changed { startDemand() }
        }
        .onDisappear { stopDemand() }
    }

    private func startDemand() {
        guard mounted else { return }
        let openingKey = key
        let retiringKey = requestedKey
        setupTask?.cancel()
        messageInteractions.close()
        handle = nil
        requestedKey = openingKey
        if let retiringKey { closeTask = bindings.beginClose(retiringKey) }
        let opening = bindings.beginOpen(
            openingKey,
            demand: .init(
                content: .card, location: .card, includingDrawers: true, screenVisibleWidth: 1400))
        let task = Task { @MainActor in
            guard let next = await opening.value else { return }
            guard !Task.isCancelled, mounted else {
                await bindings.retire(next)
                return
            }
            messageInteractions.beginOpening(next.opening.epoch, initialSelection: 0)
            self.handle = next
            onConsumerStarted(next)
            await next.opening.initialExecution.task.value
            guard !Task.isCancelled, mounted, self.handle?.opening.epoch == next.opening.epoch else {
                if self.handle?.opening.epoch == next.opening.epoch { self.handle = nil }
                await bindings.retire(next)
                return
            }
            onConsumerReadCompleted(next)
            if let value = next.atom.value { notifyPrepared(value) }
        }
        setupTask = task
        onRenderingTaskStarted(task)
    }

    private func stopDemand() {
        mounted = false
        setupTask?.cancel()
        setupTask = nil
        let closingKey = requestedKey ?? handle?.key
        requestedKey = nil
        messageInteractions.close()
        handle = nil
        if let closingKey { closeTask = bindings.beginClose(closingKey) }
    }

    private func notifyPrepared(_ value: PopoverDetail) {
        if let handle { messageInteractions.apply(value.interactions.versions, opening: handle.opening.epoch) }
        guard let card = value.card, let onApplication, preparedPublication != value.publication.id else { return }
        preparedPublication = value.publication.id
        onApplication(
            .prepared(.init(publication: value.publication, value: .card(card), feedback: value.content.feedback)))
    }
}
