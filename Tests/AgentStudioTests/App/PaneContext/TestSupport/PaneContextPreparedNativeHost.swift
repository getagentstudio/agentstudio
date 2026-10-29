import AgentStudioInfrastructure
import AgentStudioSessions
import AgentStudioSharedComponents
import AgentStudioTestHarness
import AgentStudioTestSupport
import AppKit
import Foundation
import SwiftUI
import Testing

@testable import AgentStudio
@testable import AgentStudioCore

enum PaneContextNativeRegistrationPhase: Sendable {
    case captured(PaneContextPopoverWakeProducer)
    case registered(PaneContextPopoverWakeProducer)
    case advanced(PaneContextPopoverWakeProducer)
    case superseded(PaneContextPopoverWakeProducer)
}

/// Drives the production host, refresh owner and family; native tools supply no projection stand-in.
@MainActor
final class PaneContextPreparedNativeHost {
    struct OpeningProducer: Sendable {
        let index: Int
        let task: Task<Void, Never>
        let press: UUID?
        init(index: Int, task: Task<Void, Never>, press: UUID? = nil) {
            self.index = index
            self.task = task
            self.press = press
        }
    }
    private enum OpeningFact: Sendable {
        case consumerStarted(PaneContextPopoverConsumerHandle)
        case producerEnded
    }
    @MainActor private final class OpeningProducers {
        let interactions = PaneContextPopoverInteractionState()
        var renderingTasks: [Task<Void, Never>] = []
        var actionTasks: [Task<Void, Never>] = []
        var handle: PaneContextPopoverConsumerHandle?
        var cardHandle: PaneContextPopoverConsumerHandle?
        var goToPaneTargets: [UUID] = []
        var dated: [AccessibilityLabelApplication.Event] = []
        var applications: [UUID: PaneContextPopoverApplication] = [:]
        var consumers: [Int: PaneContextPopoverConsumerHandle] = [:]
        var monitors: [Task<Void, Never>] = []
        let facts = FactRecorder<Int, OpeningFact>(
            vocabulary: .init(
                describeScope: { "native opening \($0)" }, describeFact: { String(describing: $0) },
                isClosing: { _, fact in if case .producerEnded = fact { true } else { false } }))

        func renderingStarted(_ task: Task<Void, Never>) {
            let index = renderingTasks.count
            renderingTasks.append(task)
            monitors.append(
                Task { @MainActor in
                    await task.value
                    facts.append(scope: index, fact: .producerEnded)
                })
        }
        func consumerStarted(_ consumer: PaneContextPopoverConsumerHandle) {
            handle = consumer
            if consumer.key.surface == .managementCard { cardHandle = consumer }
            let index = renderingTasks.count - 1
            consumers[index] = consumer
            facts.append(scope: index, fact: .consumerStarted(consumer))
        }
    }
    let native: PaneContextNativePopoverWindow
    let bindings: PaneContextPopoverHostBindings
    let bridge: PopoverOwnerFactBridge
    let leaf: PaneContextPreparedMessageLeafRecorder
    let clock: TestPushClock
    private let openings: OpeningProducers
    private enum OpeningKind {
        case popover(PaneContextPopoverEntry)
        case card
    }
    private let openingKind: OpeningKind

    convenience init(
        fixture: CompositionFactoryFixture, entry: PaneContextPopoverEntry,
        clock: TestPushClock, wallNow: @escaping @Sendable () -> Date,
        bridge: PopoverOwnerFactBridge, location: PaneContextPopoverLocation = .pane
    ) {
        let adapter = PaneContextUIAdapter(service: fixture.composition.paneContextService)
        let sourceOwners = PaneContextTestSourceOwners(
            sessionStatus: .init(), presentation: fixture.presentationAtom,
            pane: { _ in nil }, serviceProvider: { adapter })
        self.init(
            paneId: fixture.ownerId, sourceOwners: sourceOwners, entry: entry, clock: clock,
            wallNow: wallNow, bridge: bridge, location: location)
    }

    init(
        paneId: PaneId, sourceOwners: PaneContextTestSourceOwners, entry: PaneContextPopoverEntry,
        clock: TestPushClock, wallNow: @escaping @Sendable () -> Date,
        bridge: PopoverOwnerFactBridge, location: PaneContextPopoverLocation = .pane,
        observesApplications: Bool = true, viewportWidth: CGFloat = 280,
        onPanelHeightWrite: (@MainActor (PaneContextPopoverHeightWrite) -> Void)? = nil,
        onRenderingStarted: @escaping @MainActor () -> Void = {}
    ) {
        let openings = OpeningProducers()
        let leaf = PaneContextPreparedMessageLeafRecorder()
        let bindings = sourceOwners.bindings(clock: clock, wallNow: wallNow) { scope, fact in
            bridge.observe(scope, fact)
            leaf.observeOwner(scope, fact)
        }
        let scrolling = PaneContextNativeScrollRecorder()
        let decisions = PaneContextPresentationDecisionRecorder()
        let applicationObserver: PaneContextPopoverApplicationObserver?
        let messageObserver: (@MainActor @Sendable (PaneContextPopoverMessageApplicationEvent) -> Void)?
        if observesApplications {
            applicationObserver = { @MainActor @Sendable event in
                leaf.observePresentation(event)
                if case .applied(let value) = event { openings.applications[value.publication.id] = value }
            }
            messageObserver = { @MainActor @Sendable event in leaf.observeRow(event) }
        } else {
            applicationObserver = nil
            messageObserver = nil
        }
        let root = PaneContextPreparedPopoverHost(
            paneId: paneId, presentation: entry,
            location: location, bindings: bindings, octiconLoader: makeTestOcticonLoader(),
            onGoToPane: { openings.goToPaneTargets.append($0) },
            onRenderingTaskStarted: { task in
                openings.renderingStarted(task)
                onRenderingStarted()
            },
            onConsumerStarted: openings.consumerStarted,
            onApplication: applicationObserver, onPanelHeightWrite: onPanelHeightWrite,
            onMessageApplication: messageObserver,
            onPresentationEvent: decisions.observe, onScrollEvent: scrolling.observe,
            onDatedLabelApplication: { openings.dated.append($0) },
            onActionTaskStarted: { openings.actionTasks.append($0) },
            messageInteractions: openings.interactions)
        native = PaneContextNativePopoverWindow(
            preparedRoot: AnyView(root.frame(width: viewportWidth)), viewportWidth: viewportWidth,
            scrolling: scrolling, presentationDecisions: decisions)
        self.bindings = bindings
        self.bridge = bridge
        self.leaf = leaf
        self.clock = clock
        self.openings = openings
        openingKind = .popover(entry)
    }

    init(
        context: PaneManagementContext, sourceOwners: PaneContextTestSourceOwners,
        clock: TestPushClock, wallNow: @escaping @Sendable () -> Date, bridge: PopoverOwnerFactBridge,
        viewportWidth: CGFloat = 640, observesApplications: Bool = true, viewportHeight: CGFloat? = nil,
        decorateRoot: @MainActor (AnyView) -> AnyView = { $0 }
    ) {
        let openings = OpeningProducers()
        let leaf = PaneContextPreparedMessageLeafRecorder()
        let bindings = sourceOwners.bindings(clock: clock, wallNow: wallNow) { scope, fact in
            bridge.observe(scope, fact)
            leaf.observeOwner(scope, fact)
        }
        let readers = PaneContextUIReaders(
            sessionStatus: sourceOwners.sessionStatus, presentation: sourceOwners.presentation,
            pane: sourceOwners.pane, popoverBindings: bindings)
        let scrolling = PaneContextNativeScrollRecorder()
        let decisions = PaneContextPresentationDecisionRecorder()
        let applicationObserver: PaneContextPopoverApplicationObserver?
        let messageObserver: (@MainActor @Sendable (PaneContextPopoverMessageApplicationEvent) -> Void)?
        if observesApplications {
            applicationObserver = { @MainActor @Sendable event in
                leaf.observePresentation(event)
                if case .applied(let value) = event { openings.applications[value.publication.id] = value }
            }
            messageObserver = { @MainActor @Sendable event in leaf.observeRow(event) }
        } else {
            applicationObserver = nil
            messageObserver = nil
        }
        let root = PaneContextPreparedManagementOverlay(
            context: context, octiconLoader: makeTestOcticonLoader(),
            readers: readers, bindings: bindings, onGoToPane: { openings.goToPaneTargets.append($0) },
            onRenderingTaskStarted: openings.renderingStarted, onConsumerStarted: openings.consumerStarted,
            onApplication: applicationObserver,
            onMessageApplication: messageObserver,
            onPresentationEvent: decisions.observe, onScrollEvent: scrolling.observe,
            onActionTaskStarted: { openings.actionTasks.append($0) },
            messageInteractions: openings.interactions)
        native = PaneContextNativePopoverWindow(
            preparedRoot: decorateRoot(AnyView(root.frame(width: viewportWidth))), viewportWidth: viewportWidth,
            isCard: true,
            viewportHeight: viewportHeight, scrolling: scrolling, presentationDecisions: decisions)
        self.bindings = bindings
        self.bridge = bridge
        self.leaf = leaf
        self.clock = clock
        self.openings = openings
        openingKind = .card
    }

    var handle: PaneContextPopoverConsumerHandle? { openings.handle }
    var interactions: PaneContextPopoverInteractionState { openings.interactions }
    var cardHandle: PaneContextPopoverConsumerHandle? { openings.cardHandle }
    var value: PopoverDetail? { handle?.atom.value }
    var cardValue: PopoverDetail? { openings.cardHandle?.atom.value }
    var goToPaneTargets: [UUID] { openings.goToPaneTargets }

    /// Supplies ordinary input through the production opening/version fence; native Submit still owns delivery.
    /// Physical radio/picker selection is the separately commissioned native journey.
    func bindSingleChoice(_ option: String, row: MessageRowModel.Key) throws {
        let handle = try #require(handle)
        let value = try currentValue(of: handle)
        try #require(value.interactions.versions[row] != nil, "The exact row has no current input version")
        let input = interactions.bindings(
            versions: value.interactions.versions, opening: handle.opening.epoch,
            currentVersions: { handle.atom.latestAcceptedValue?.interactions.versions })
        let draft = input.draft(row)
        var selected = draft.wrappedValue
        selected.setChoice(option, selected: true, allowsMultiple: false)
        draft.wrappedValue = selected
        #expect(draft.wrappedValue.selectedChoices == [option])
        native.layout()
        let submit = try #require(
            native.find("pane-context.submit." + row.controlScope) as? any NSAccessibilityProtocol,
            "The native Submit control must remain present after local selection")
        try #require(submit.isAccessibilityEnabled())
    }

    func beginOpening(_ explicitIdentifier: String? = nil) throws -> OpeningProducer {
        let count = openings.renderingTasks.count
        let identifier: String
        if let explicitIdentifier {
            identifier = explicitIdentifier
        } else {
            switch openingKind {
            case .card: identifier = "pane-context.card-messages"
            case .popover(let entry):
                switch entry {
                case .messagesAction(let control, _): identifier = control.identifier
                case .kind(let chip): identifier = "pane-context.messages.\(chip.kind)"
                case .agentLine: identifier = "pane-context.agent-line"
                }
            }
        }
        let press = try native.press(identifier)
        try #require(
            openings.renderingTasks.count == count + 1,
            "Native press ended without announcing its actual rendering producer")
        return .init(index: count, task: openings.renderingTasks[count], press: press)
    }

    func consumer(for producer: OpeningProducer) async throws -> PaneContextPopoverConsumerHandle {
        let fact = try await openings.facts.expectNext(
            in: producer.index, where: { _ in true },
            "the native opening's actual consumer or producing-task end")
        guard case .consumerStarted(let handle) = fact else { throw OpeningFailure.endedWithoutConsumer }
        return handle
    }

    func completeOpening(_ producer: OpeningProducer) async throws {
        await producer.task.value
        let handle = try #require(
            openings.consumers[producer.index], "Rendering producer ended without its own consumer")
        try await consumePublished(handle.opening.initialExecution, handle: handle)
    }

    func open() async throws {
        switch openingKind {
        case .popover: try await completeOpening(try beginOpening())
        case .card:
            try #require(!openings.renderingTasks.isEmpty, "Mounted card did not announce its actual opening producer")
            try await completeOpening(.init(index: 0, task: openings.renderingTasks[0]))
        }
    }

    func rendered() async throws {
        // Production paints atom.value during invalidation; currentness separately gates actions and dated-leaf proofs.
        let value = try #require(handle?.atom.value, "The native host has no retained presentation")
        let window = try #require(
            handle?.key.surface == .managementCard ? native.window : native.popoverWindow,
            "The native host did not mount for its published value")
        let host = try #require(window.contentView)
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        if case .note(let text) = value.content.body {
            let leaf = try #require(native.find("pane-context.feedback") as? any NSAccessibilityProtocol)
            #expect(leaf.accessibilityLabel() == text)
        } else {
            try #require(
                openings.applications[value.publication.id] != nil,
                "Exact native application missing after its one owning-host update: \(value.publication.request)")
        }
    }

    func renderedCard() async throws {
        let value = try currentValue(of: openings.cardHandle)
        let host = try #require(native.window.contentView)
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()
        native.window.displayIfNeeded()
        try #require(
            openings.applications[value.publication.id] != nil,
            "Exact card native application missing after its host update")
    }

    /// Joins only the actual text-width inputs announced by the preceding native update.
    func bodyLayoutsPrepared() async throws {
        let handle = try #require(handle)
        let window = native.popoverWindow ?? native.window
        let host = try #require(window.contentView)
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let producers = bindings.inputs.forwardingTasks(for: handle.key, opening: handle.opening.epoch)
        for producer in producers { await producer.value }
        try await rendered()
        try #require(
            handle.atom.value?.bodyMeasurements.isEmpty == false,
            "The native width producer ended or retired without a prepared body layout")
    }

    func renderedNote(_ text: String) async throws {
        let window = native.popoverWindow ?? native.window
        let host = try #require(window.contentView)
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let label = try #require(
            native.find("pane-context.feedback") as? any NSAccessibilityProtocol,
            "Exact native note missing after one owning-host update: \(text)")
        #expect(label.accessibilityLabel() == text)
    }

    func actionProducer(_ index: Int = 0) throws -> Task<Void, Never> {
        try #require(
            openings.actionTasks.indices.contains(index), "Native press did not announce its actual action task")
        return openings.actionTasks[index]
    }

    func actionCompleted(_ index: Int = 0) async throws {
        let producer = try actionProducer(index)
        await producer.value
    }

    func advance(
        by duration: Duration, registeredAt deadline: TestPushClock.Instant,
        onRegistration: (@MainActor (PaneContextNativeRegistrationPhase) async throws -> Void)? = nil
    ) async throws {
        let handle = try #require(handle)
        let previous = try #require(await bindings.owner.latestExecution(for: handle.key))
        let initial = try #require(
            await bindings.owner.scheduledWakeProducer(), "No useful age deadline was registered")
        let wake = try await advanceRegisteredWake(
            initial, for: handle, by: duration, at: deadline, onRegistration: onRegistration)
        await wake.task.value
        let owner = try #require(bindings.owner as? PaneContextPopoverRefreshOwner<TestPushClock>)
        let next = try await awaitDueNativeExecution(
            on: owner, key: handle.key, opening: handle.opening.epoch,
            after: previous.id, retiredWake: wake.sequence)
        try await consumePublished(next, handle: handle)
    }

    /// A registration authorizes time drive only while its actual producer remains current.
    private func advanceRegisteredWake(
        _ initial: PaneContextPopoverWakeProducer, for handle: PaneContextPopoverConsumerHandle,
        by duration: Duration, at deadline: TestPushClock.Instant,
        onRegistration: (@MainActor (PaneContextNativeRegistrationPhase) async throws -> Void)?
    ) async throws -> PaneContextPopoverWakeProducer {
        var wake = initial
        var joinedWakes = Set<UInt64>()
        while true {
            try #require(
                joinedWakes.insert(wake.sequence).inserted, "A cancelled registration producer made no progress")
            try await onRegistration?(.captured(wake))
            let sequence = wake.sequence
            let producer = wake.task
            let bridge = bridge
            let scope = PopoverOwnerProofScope(channel: .owner(.deadline(sequence)))
            openings.monitors.append(
                Task {
                    await producer.value
                    if !bridge.didFinish(.deadline(sequence)) {
                        bridge.facts.append(scope: scope, fact: .producerEnded)
                    }
                })
            try await bridge.facts.expectNext(in: scope, .owner(.deadlineArmed))
            let outcome = try await bridge.facts.expectNext(
                in: scope, where: { _ in true }, "clock registration or this wake's terminal outcome")
            if case .clockRegistered(let observed) = outcome {
                try #require(observed == deadline, "The useful clock registration must match the driven deadline")
                try await onRegistration?(.registered(wake))
                let owner = try #require(bindings.owner as? PaneContextPopoverRefreshOwner<TestPushClock>)
                let advanced = try await advanceNativeClockIfCurrent(
                    on: owner, key: handle.key, opening: handle.opening.epoch, wake: wake.sequence, by: duration)
                if advanced {
                    try await onRegistration?(.advanced(wake))
                    return wake
                }
                try await onRegistration?(.superseded(wake))
                try await bridge.facts.expectNext(in: scope, .owner(.deadlineEnded(cancelled: true)))
            } else {
                try #require(
                    outcome == .owner(.deadlineEnded(cancelled: true)),
                    "The wake ended without registration or legal replacement: \(outcome)")
            }
            await producer.value
            let owner = try #require(bindings.owner as? PaneContextPopoverRefreshOwner<TestPushClock>)
            wake = try await awaitNativeRegistrationSuccessor(
                on: owner, key: handle.key, opening: handle.opening.epoch)
        }
    }

    func canonicalChangeCompleted(_ forwarding: [Task<Void, Never>]) async throws {
        try #require(!forwarding.isEmpty, "Canonical owner change announced no actual forwarding producer")
        for producer in forwarding { await producer.value }
        try await advance(by: .seconds(10), registeredAt: clock.now.advanced(by: .seconds(10)))
    }

    func refresh() async throws {
        let handle = try #require(handle)
        for forwarding in bindings.inputs.forwardingTasks(for: handle.key, opening: handle.opening.epoch) {
            await forwarding.value
        }
        let previous = await bindings.owner.latestExecution(for: handle.key)
        await bindings.owner.refreshImmediately(handle.key, opening: handle.opening.epoch)
        await previous?.task.value
        let next = try #require(await bindings.owner.latestExecution(for: handle.key))
        try #require(next.id != previous?.id, "Immediate refresh produced no successor execution")
        try await consumePublished(next, handle: handle)
    }

    func appliedMessage(_ key: MessageRowModel.Key, expectedLabel: String, age: String, isRead: Bool) throws
        -> PaneContextMessageTextApplication.Value
    {
        let value = try currentValue(of: handle)
        let target = PaneContextPreparedMessageLeafRecorder.Target(value.publication, row: key)
        try leaf.requireCurrent(target)
        let identifier = "pane-context.message-text." + key.controlScope
        try forceOwningHost(identifier: identifier)
        let applied = try #require(
            leaf.applied(to: target),
            "D57 immediate native leaf missing: key=\(target) leaf=\(identifier) age=\(age) read=\(isRead)")
        #expect(applied.row.age.text == age)
        #expect(applied.row.isRead == isRead)
        #expect(applied.native.key.producerId == target.producer.id)
        #expect(applied.native.key.valueId == target.publication)
        #expect(applied.native.identifier == identifier)
        #expect(
            applied.native.label == expectedLabel,
            "The actual AX leaf must contain the independently expected dated text")
        #expect((native.find(identifier) as? any NSAccessibilityProtocol)?.accessibilityLabel() == applied.native.label)
        return applied
    }

    func appliedAgentLine(summary: String, age: String) throws {
        let value = try currentValue(of: handle)
        let publication = value.publication
        try leaf.requireCurrent(publication)
        try forceOwningHost(identifier: AgentLinePopover.datedLabelIdentifier)
        let latest = openings.dated.last { event in
            let key: AccessibilityLabelApplication.Key
            switch event {
            case .applied(let value), .retired(let value): key = value.key
            case .updateEnded: return false
            }
            return key.producerId == publication.producer.id && key.valueId == publication.id
        }
        if case .retired = latest { throw OpeningFailure.nativeLeafRetired }
        let applied: AccessibilityLabelApplication.Value?
        if case .applied(let value) = latest { applied = value } else { applied = nil }
        let exact = try #require(
            applied,
            "D57 immediate dated leaf missing: key=\(publication.request) publication=\(publication.id) leaf=\(AgentLinePopover.datedLabelIdentifier) age=\(age)"
        )
        #expect(exact.identifier == AgentLinePopover.datedLabelIdentifier)
        #expect(exact.label == summary + " [" + age + "]")
        #expect((native.find(exact.identifier) as? any NSAccessibilityProtocol)?.accessibilityLabel() == exact.label)
    }

    private func forceOwningHost(identifier: String) throws {
        let native = try #require(
            native.find(identifier) as? NSView,
            "The owning native leaf is absent before its single forced update: \(identifier)")
        let window = try #require(native.window, "The exact native leaf retired before its forced update")
        let host = try #require(window.contentView)
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }

    private func consumePublished(
        _ execution: PaneContextPopoverExecution,
        handle: PaneContextPopoverConsumerHandle
    ) async throws {
        await execution.task.value
        try #require(
            bridge.didFinish(.execution(handle.key, execution.id)),
            "Owner producer ended without a terminal fact for its exact execution")
        let scope = PopoverOwnerProofScope(channel: .owner(.execution(handle.key, execution.id)))
        while true {
            let fact = try await bridge.facts.expectNext(
                in: scope, where: { _ in true },
                "exact publication or owner failure, supersession, cancellation, retirement")
            if case .owner(.finished(let finish)) = fact {
                try #require(
                    finish == .published || finish == .equal, "Owner failed to publish current value: \(finish)")
                return
            }
        }
    }

    func close() async throws {
        try await native.close()
        await bindings.stop()
        for task in openings.renderingTasks {
            task.cancel()
            await task.value
        }
        for task in openings.actionTasks {
            task.cancel()
            await task.value
        }
        for monitor in openings.monitors { await monitor.value }
        openings.facts.receive(.ended)
        try await openings.facts.finish()
        #expect(clock.pendingSleepCount == 0)
        bridge.facts.receive(.ended)
        try await bridge.facts.finish()
    }
    private func currentValue(of handle: PaneContextPopoverConsumerHandle?) throws -> PopoverDetail {
        guard let handle, let value = handle.atom.value, let accepted = handle.atom.latestAcceptedValue,
            handle.atom.isCurrent(accepted.publication.request)
        else { throw OpeningFailure.pendingOrRetired }
        return value
    }

    private enum OpeningFailure: Error { case endedWithoutConsumer, pendingOrRetired, nativeLeafRetired }
}
