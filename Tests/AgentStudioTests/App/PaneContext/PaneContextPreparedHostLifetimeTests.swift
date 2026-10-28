import AgentStudioInfrastructure
import AgentStudioSharedComponents
import AgentStudioTestSupport
import AppKit
import SwiftUI
import Testing

@testable import AgentStudio
@testable import AgentStudioCore

@MainActor
@Suite("Prepared native host lifetimes", .serialized)
struct PaneContextPreparedHostLifetimeTests {
    enum End: Sendable, CaseIterable { case cancelledAtPress, cancelledAfterConsumer, windowRetired }

    @Test(
        "S4 a native opening producer ending through cancellation or view retirement drains its exact demand",
        arguments: End.allCases)
    func endedRenderingProducerRetiresItsDemand(_ ending: End) async throws {
        let fixture = try await CompositionFactoryFixture.make()
        let adapter = PaneContextUIAdapter(service: fixture.composition.paneContextService)
        let bridge = PopoverOwnerFactBridge()
        let clock = TestPushClock(pendingSleepFactSink: bridge.observeClock)
        let time = PaneContextTestTime(clock: clock)
        let bindings = PaneContextPopoverHostBindings(
            clock: clock, wallNow: { time.now },
            readSource: { _ in
                .init(structuralFacts: nil, title: "Owner", note: nil, session: nil, display: nil, activity: nil)
            },
            serviceProvider: { adapter }, observe: bridge.observe)
        var tasks: [Task<Void, Never>] = []
        let root = PaneContextPreparedPopoverHost(
            paneId: fixture.ownerId,
            presentation: .messagesAction(PaneContextPopoverControlProjection.controls().messages, focusedMessage: nil),
            location: .pane, bindings: bindings, octiconLoader: makeTestOcticonLoader(), onGoToPane: { _ in },
            onRenderingTaskStarted: { task in
                tasks.append(task)
                if ending == .cancelledAtPress { task.cancel() }
            },
            onConsumerStarted: { _ in
                if ending == .cancelledAfterConsumer { tasks.last?.cancel() }
            })
        let native = PaneContextNativePopoverWindow(preparedRoot: AnyView(root))
        do {
            try native.press("pane-context.messages")
            try #require(tasks.count == 1, "Native press did not synchronously announce its actual producer")
            if ending == .windowRetired { native.window.close() }
            await tasks[0].value
            let observed = bridge.observedConsumers
            if ending != .windowRetired { try #require(observed.count == 1) }
            for (key, _) in observed {
                #expect(
                    await bindings.owner.latestExecution(for: key) == nil,
                    "An ended native rendering producer left its consumer and read/age demand alive")
            }
            try await native.close()
            await bindings.stop()
            for task in tasks {
                task.cancel()
                await task.value
            }
            #expect(clock.pendingSleepCount == 0)
            bridge.facts.receive(.ended)
            try await bridge.facts.finish()
            try await fixture.close()
        } catch {
            try? await native.close()
            await bindings.stop()
            for task in tasks {
                task.cancel()
                await task.value
            }
            bridge.facts.receive(.ended)
            try? await bridge.facts.finish()
            try? await fixture.close()
            throw error
        }
    }

    enum RetargetSurface: Sendable, CaseIterable { case popover, toolbar, card }

    @Test(
        "S4 reusing a native host for another pane retires the previous consumer key",
        arguments: RetargetSurface.allCases)
    func retargetedHostDoesNotKeepItsPreviousPaneAlive(_ surface: RetargetSurface) async throws {
        try await withAsyncTestCoreAtoms { atoms in
            let store = WorkspaceStore(
                catalogAtom: atoms.workspaceRepositoryTopology, graphAtom: atoms.workspacePane,
                interactionAtom: atoms.workspaceTabLayout)
            let firstPane = store.createPane(title: "First pane")
            let secondPane = store.createPane(title: "Second pane")
            defer {
                store.removePane(firstPane.id)
                store.removePane(secondPane.id)
            }
            let firstId = PaneId(existingUUID: firstPane.id)
            let secondId = PaneId(existingUUID: secondPane.id)
            let fixture = try await CompositionFactoryFixture.make(ownerId: firstId)
            fixture.directory.install(
                .init(
                    workspaceId: fixture.workspaceId, membershipRevision: 2,
                    entries: [
                        .init(paneId: firstId, placement: .layout, ownedDrawerChildIds: []),
                        .init(paneId: secondId, placement: .layout, ownedDrawerChildIds: []),
                    ]))
            await fixture.composition.paneContextService.reconcileMembership()
            await fixture.composition.presentationLane.publishPending()
            let adapter = PaneContextUIAdapter(service: fixture.composition.paneContextService)
            let bridge = PopoverOwnerFactBridge()
            let clock = TestPushClock(pendingSleepFactSink: bridge.observeClock)
            let time = PaneContextTestTime(clock: clock)
            let owners = PaneContextTestSourceOwners(
                sessionStatus: .init(), presentation: fixture.presentationAtom,
                pane: { store.paneAtom.pane($0.uuid) }, serviceProvider: { adapter })
            let bindings = owners.bindings(clock: clock, wallNow: { time.now }, observe: bridge.observe)
            let readers = PaneContextUIReaders(
                sessionStatus: owners.sessionStatus, presentation: owners.presentation,
                pane: owners.pane, popoverBindings: bindings)
            let recorder = RetargetRecorder()
            @MainActor func root(_ pane: PaneId) -> AnyView {
                AnyView(
                    RetargetedHostView(
                        surface: surface, pane: pane,
                        context: .project(paneId: pane.uuid, store: store), readers: readers,
                        bindings: bindings, recorder: recorder))
            }
            let native = PaneContextNativePopoverWindow(
                preparedRoot: root(firstId),
                viewportWidth: surface == .card ? 640 : 280, isCard: surface == .card)
            do {
                if surface == .popover { try native.press("pane-context.messages") }
                try #require(recorder.tasks.count == 1)
                await recorder.tasks[0].value
                let first = try #require(recorder.handles.first)
                try #require(first.key.paneId == firstId && first.atom.value != nil)
                let hosting = try #require(native.window.contentView as? NSHostingView<AnyView>)
                hosting.rootView = root(secondId)
                hosting.needsLayout = true
                _ = hosting.fittingSize
                hosting.layoutSubtreeIfNeeded()
                native.window.displayIfNeeded()
                let probe = try #require(native.find("pane-context.fixture-pane-input") as? any NSAccessibilityProtocol)
                try #require(
                    probe.accessibilityLabel() == secondId.uuidString, "The fixture did not apply its new pane input")
                if surface == .popover { try native.press("pane-context.messages") }
                try #require(
                    recorder.tasks.count == 2, "The retargeted native control did not announce its real producer")
                await recorder.tasks[1].value
                let second = try #require(recorder.handles.last)
                try #require(second.key.paneId == secondId, "The fixture did not apply its new pane input")
                try #require(first.key.hostId == second.key.hostId, "The fixture recreated instead of reusing the host")
                #expect(second.atom.value != nil)
                #expect(
                    await bindings.owner.latestExecution(for: first.key) == nil,
                    "Retargeting left the old pane consumer demanded after its replacement opened")
                try await native.close()
                await bindings.stop()
                for task in recorder.tasks {
                    task.cancel()
                    await task.value
                }
                #expect(clock.pendingSleepCount == 0)
                bridge.facts.receive(.ended)
                try await bridge.facts.finish()
                try await fixture.close()
            } catch {
                try? await native.close()
                await bindings.stop()
                for task in recorder.tasks {
                    task.cancel()
                    await task.value
                }
                bridge.facts.receive(.ended)
                try? await bridge.facts.finish()
                try? await fixture.close()
                throw error
            }
        }
    }

    private final class RetargetRecorder {
        var tasks: [Task<Void, Never>] = []
        var handles: [PaneContextPopoverConsumerHandle] = []
    }
    private struct RetargetedHostView: View {
        let surface: RetargetSurface
        let pane: PaneId
        let context: PaneManagementContext
        let readers: PaneContextUIReaders
        let bindings: PaneContextPopoverHostBindings
        let recorder: RetargetRecorder

        var body: some View {
            Group {
                switch surface {
                case .popover:
                    PaneContextPreparedPopoverHost(
                        paneId: pane,
                        presentation: .messagesAction(
                            PaneContextPopoverControlProjection.controls().messages, focusedMessage: nil),
                        location: .pane, bindings: bindings, octiconLoader: makeTestOcticonLoader(),
                        onGoToPane: { _ in },
                        onRenderingTaskStarted: { recorder.tasks.append($0) },
                        onConsumerStarted: { recorder.handles.append($0) })
                case .toolbar:
                    PaneContextPreparedToolbarControls(
                        paneId: pane, bindings: bindings,
                        octiconLoader: makeTestOcticonLoader(), onGoToPane: { _ in },
                        onRenderingTaskStarted: { recorder.tasks.append($0) },
                        onConsumerStarted: { recorder.handles.append($0) })
                case .card:
                    PaneContextPreparedManagementOverlay(
                        context: context, octiconLoader: makeTestOcticonLoader(),
                        readers: readers, bindings: bindings, onGoToPane: { _ in },
                        onRenderingTaskStarted: { recorder.tasks.append($0) },
                        onConsumerStarted: { recorder.handles.append($0) })
                }
            }.background {
                AccessibilityLabelBridge(identifier: "pane-context.fixture-pane-input", label: pane.uuidString)
            }
        }
    }
}
