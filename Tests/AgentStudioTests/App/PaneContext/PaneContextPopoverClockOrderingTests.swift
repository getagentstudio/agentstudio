import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioTestHarness
import AppKit
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioSharedComponents

/// A wrong wait can make the real G11/G12 test pass before its label is current.
@MainActor
@Suite("Agent Line native label application ordering", .serialized)
struct PaneContextPopoverClockOrderingTests {
    enum WaitFact: Equatable, Sendable {
        case decision(NativeCardApplicationWaitDecision)
        case taskEnded
    }

    @Test("The container receipt cannot complete an Agent Line wait before its native dated label")
    func parentApplicationCannotStandForTheDatedLabel() async throws {
        let fixture = try await preparedFixture()
        let (facts, waiter) = beginWait(fixture)
        do {
            // A duplicate old label frame must not join the new frame from the same worker.
            fixture.reapplyInitialLabel()
            fixture.parent.layout()
            let decision = try await nextWaitDecision(facts, fixture)
            try #require(decision == .decision(.waitingForDatedLabel(fixture.worker)))
            #expect(fixture.label.accessibilityLabel() == "The dated line [Now]")
            fixture.applyCurrentLabel()
            let received = try await waiter.value
            #expect(received == fixture.application.value)
            #expect(fixture.label.accessibilityLabel() == "The dated line [1 min ago]")
            try await fixture.close()
            facts.receive(.ended)
            try await facts.finish()
        } catch {
            fixture.endWorker()
            _ = await waiter.result
            try? await fixture.close()
            facts.receive(.ended)
            try? await facts.finish()
            throw error
        }
    }

    @Test("Retiring the dated AX consumer ends a pending label wait with that cause")
    func nativeLabelRetirementEndsTheAgeWait() async throws {
        let fixture = try await preparedFixture()
        let (facts, waiter) = beginWait(fixture)
        do {
            fixture.parent.layout()
            let decision = try await nextWaitDecision(facts, fixture)
            try #require(decision == .decision(.waitingForDatedLabel(fixture.worker)))
            fixture.label.retireLabelApplication()
            // The real producer's ending is a fallback exit if label retirement forwarding breaks.
            fixture.endWorker()
            do {
                _ = try await waiter.value
                Issue.record("A retired dated label must not complete an age application")
            } catch {
                #expect(String(describing: error).contains("dated AX label retired"), "Wrong label ending: \(error)")
            }
            try await fixture.close()
            facts.receive(.ended)
            try await facts.finish()
        } catch {
            fixture.endWorker()
            _ = await waiter.result
            try? await fixture.close()
            facts.receive(.ended)
            try? await facts.finish()
            throw error
        }
    }

    private func preparedFixture() async throws -> NativeDatedLabelOrderingFixture {
        let fixture = await NativeDatedLabelOrderingFixture.make()
        do {
            try await fixture.applyInitialFrame()
            await fixture.prepareNextFrame()
            return fixture
        } catch {
            try? await fixture.close()
            throw error
        }
    }

    private func beginWait(_ fixture: NativeDatedLabelOrderingFixture)
        -> (FactRecorder<UUID, WaitFact>, Task<PaneManagementIdentityCapture.VisiblePresentation, any Error>)
    {
        let facts = FactRecorder<UUID, WaitFact>(
            vocabulary: .init(
                describeScope: { "Agent Line wait \($0)" }, describeFact: { String(describing: $0) },
                isClosing: { _, fact in fact == .taskEnded }))
        fixture.clock.onApplicationWaitDecision = { facts.append(scope: fixture.worker, fact: .decision($0)) }
        let waiter = Task {
            defer { facts.append(scope: fixture.worker, fact: .taskEnded) }
            return try await fixture.clock.applied(pane: fixture.pane.uuid, input: nil)
        }
        return (facts, waiter)
    }

    private func nextWaitDecision(
        _ facts: FactRecorder<UUID, WaitFact>, _ fixture: NativeDatedLabelOrderingFixture
    ) async throws -> WaitFact {
        try await facts.expectNext(
            in: fixture.worker, where: { _ in true }, "wait decision or producing task ending")
    }
}

/// Real native application/AX writers calibrate the wait; G11/G12 cover the mounted product path.
@MainActor
private final class NativeDatedLabelOrderingFixture {
    let pane: PaneId
    let worker = UUIDv7.generate()
    let clock = NativeCardTestClock()
    let parent = NativePresentationApplicationView<PaneRelativeTimeRefresh.Application>()
    let label = AccessibilityLabelBridgeView()
    let window: NSWindow
    let input: PaneManagementIdentityCapture.VisibleInput
    let initial: PaneContextPopoverShape
    private(set) var application: PaneRelativeTimeRefresh.Application
    private let initialApplication: PaneRelativeTimeRefresh.Application
    private var workerEnded = false

    static func make() async -> NativeDatedLabelOrderingFixture {
        let pane = PaneId.generateUUIDv7()
        let now = Date(timeIntervalSince1970: 2)
        let line = AgentLineDetail(summary: "The dated line", refs: [], writer: .pane(pane), updatedAt: now)
        let initial = await PaneContextPopoverShaping.shape(
            PaneContextPopoverShapingTests.detail(paneId: pane, line: line), sourceTitles: [:], counts: .zero, now: now)
        return .init(pane: pane, initial: initial)
    }

    private init(pane: PaneId, initial: PaneContextPopoverShape) {
        self.pane = pane
        self.initial = initial
        input = .popover(initial, .agentLine)
        let application = PaneRelativeTimeRefresh.Application(
            input: input, value: .popover(initial), operationId: worker)
        self.application = application
        initialApplication = application
        label.identifier = .init("pane-context.agent-line-dated-text")
        let root = NSView(frame: .init(x: 0, y: 0, width: 320, height: 80))
        root.addSubview(parent)
        root.addSubview(label)
        window = NSWindow(contentRect: root.frame, styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        clock.observeOwner(.operation(input, .started, id: worker))
    }

    func applyInitialFrame() async throws {
        prepareParent()
        parent.layout()
        reapplyInitialLabel()
        #expect(try await clock.applied(pane: pane.uuid, input: nil) == .popover(initial))
    }

    func prepareNextFrame() async {
        let next = await PaneContextPopoverShaping.refresh(
            initial, content: .agentLine, now: Date(timeIntervalSince1970: 62))
        application = .init(input: input, value: .popover(next.shape), operationId: worker)
        prepareParent()
    }

    func reapplyInitialLabel() { applyLabel("The dated line [Now]", application: initialApplication) }
    func applyCurrentLabel() { applyLabel("The dated line [1 min ago]", application: application) }

    private func applyLabel(_ text: String, application: PaneRelativeTimeRefresh.Application) {
        label.applyLabel(
            text,
            application: .init(
                key: .init(producerId: worker, valueId: application.applicationId), observe: clock.observeDatedLabel))
    }

    private func prepareParent() {
        clock.observePreparation(input, id: worker)
        parent.prepare(
            application, onApplied: { [clock] in clock.observeOwner(.applied($0)) },
            onRetired: { [clock] in clock.observeOwner(.applicationRetired($0)) })
    }

    func endWorker() {
        guard !workerEnded else { return }
        workerEnded = true
        clock.observeOwner(.ended(input, .cancelled, id: worker))
    }

    func close() async throws {
        label.retireLabelApplication()
        parent.retire()
        window.contentView = nil
        window.close()
        endWorker()
        clock.onApplicationWaitDecision = nil
        try await clock.retire()
        try await clock.facts.finish()
    }
}
