import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioRepoExplorer
import AgentStudioSharedComponents
import AgentStudioTestSupport
import AppKit
import SwiftUI
import Synchronization
import Testing

@testable import AgentStudio
@testable import AgentStudioSessions

extension PaneManagementIdentityHostTests {
    @Test("G11 the production card paints an eight-day-old stored Agent Line and schedules tomorrow")
    func eightDayStoredLineReachesNativeCard() async throws {
        let fixture = try await StoredMessageCardFixture.make(hasActivity: false, messageAgeSeconds: 8 * 86_400)
        let clock = fixture.clock
        let pane = fixture.context.paneId
        let start = clock.now
        do {
            try #require(try await clock.nextOperation(pane: pane, input: nil) == .started)
            try await clock.entered(pane: pane, input: nil)
            try await clock.registered(start.advanced(by: .seconds(86_400)), pane: pane, currentInput: nil)
            try fixture.expectRendered(age: "[8 days ago]", activity: nil)
            let read = await fixture.composition.composition.paneContextService.readDetail(
                .init(paneId: .init(existingUUID: pane), page: .first))
            guard case .detail(let detail) = read else { throw StoredMessageCardFailure.missingDetail }
            #expect(detail.agentLine == fixture.written)
            #expect(fixture.written.summary == "Message before the current activity")
            #expect(fixture.written.updatedAt == Date(timeIntervalSince1970: 1_800_000_000))
            fixture.hide()
            try #require(try await clock.nextHideResult() == .cancelled(requested: true))
            try await clock.cancelledWorker(pane: pane, input: nil)
            #expect(clock.pendingSleepCount == 0)
            try await clock.finish()
            try await fixture.close()
        } catch {
            fixture.hide()
            try? await clock.retire()
            try? await clock.facts.finish()
            try? await fixture.close()
            throw error
        }
    }

    @Test(
        "a real stored message and Working hook reach the same visible card across their own deadlines",
        arguments: [false, true])
    func storedMessageAndHookReachVisibleCard(hasActivity: Bool) async throws {
        let fixture = try await StoredMessageCardFixture.make(hasActivity: hasActivity)
        let clock = fixture.clock
        let pane = fixture.context.paneId
        let input = hasActivity ? clock.now : nil
        let start = clock.now
        do {
            try #require(try await clock.nextOperation(pane: pane, input: input) == .started)
            try await clock.entered(pane: pane, input: input)
            try await clock.registered(start.advanced(by: .seconds(55)), pane: pane, currentInput: input)
            try fixture.expectRendered(age: "[2 min ago]", activity: hasActivity ? "Now" : nil)
            let identity = ObjectIdentifier(fixture.host)

            clock.advance(by: .seconds(55))
            try await clock.registered(
                start.advanced(by: .seconds(hasActivity ? 60 : 115)), pane: pane, currentInput: input)
            try fixture.expectRendered(age: "[3 min ago]", activity: hasActivity ? "Now" : nil)
            #expect(ObjectIdentifier(fixture.host) == identity)
            if hasActivity {
                clock.advance(by: .seconds(5))
                try await clock.registered(start.advanced(by: .seconds(115)), pane: pane, currentInput: input)
                try fixture.expectRendered(age: "[3 min ago]", activity: "1 min ago")
            }
            clock.advance(by: .seconds(hasActivity ? 3540 : 3545))
            try await clock.registered(start.advanced(by: .seconds(7075)), pane: pane, currentInput: input)
            try fixture.expectRendered(age: "[1 hr ago]", activity: hasActivity ? "1 hr ago" : nil)
            clock.advance(by: .seconds(82_800))
            try await clock.registered(start.advanced(by: .seconds(172_675)), pane: pane, currentInput: input)
            try fixture.expectRendered(age: "[1 day ago]", activity: hasActivity ? "1 day ago" : nil)
            clock.advance(by: .seconds(86_400))
            try await clock.registered(start.advanced(by: .seconds(259_075)), pane: pane, currentInput: input)
            try fixture.expectRendered(age: "[2 days ago]", activity: hasActivity ? "2 days ago" : nil)
            let read = await fixture.composition.composition.paneContextService.readDetail(
                .init(paneId: .init(existingUUID: pane), page: .first))
            guard case .detail(let detail) = read else {
                Issue.record("Stored message could not be read after native refresh")
                throw StoredMessageCardFailure.missingDetail
            }
            #expect(detail.agentLine == fixture.written)
            #expect(fixture.written.updatedAt == Date(timeIntervalSince1970: 1_800_000_000))
            fixture.hide()
            try #require(try await clock.nextHideResult() == .cancelled(requested: true))
            try await clock.cancelledWorker(pane: pane, input: input)
            #expect(clock.pendingSleepCount == 0)
            try await clock.finish()
            try await fixture.close()
        } catch {
            fixture.hide()
            try? await clock.retire()
            try? await clock.facts.finish()
            try? await fixture.close()
            throw error
        }
    }
}

private enum StoredMessageCardFailure: Error { case missingDetail }

@MainActor
private final class StoredMessageCardFixture {
    let composition: CompositionFactoryFixture
    let store: WorkspaceStore
    let context: PaneManagementContext
    let written: AgentLineDetail
    let clock: NativeCardTestClock
    let host: NSHostingView<AnyView>
    let window: NSWindow
    private let atoms: CoreAtoms
    private let loader: OcticonLoader

    private init(
        composition: CompositionFactoryFixture, store: WorkspaceStore, atoms: CoreAtoms,
        written: AgentLineDetail, readers: PaneContextUIReaders, clock: NativeCardTestClock, wallNow: Date
    ) {
        self.composition = composition
        self.store = store
        self.atoms = atoms
        self.written = written
        self.clock = clock
        context = .project(paneId: composition.ownerId.uuid, store: store)
        loader = makeTestOcticonLoader()
        host = NSHostingView(
            rootView: AnyView(
                ManagementPaneIdentityOverlay(
                    context: context, octiconLoader: loader, store: store, clock: clock, wallNow: wallNow,
                    onRelativeTimeEvent: { clock.observeOwner($0) }
                )
                .environment(\.paneContextUIReaders, readers)
                .frame(width: 1000, height: 360, alignment: .topLeading)
                .background(Color.black).environment(\.colorScheme, .dark)))
        host.frame = CGRect(x: 0, y: 0, width: 1000, height: 360)
        window = NSWindow(contentRect: host.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
    }

    static func make(hasActivity: Bool, messageAgeSeconds: Double = 125) async throws -> StoredMessageCardFixture {
        installTestCoreAtomsIfNeeded()
        let atoms = CoreAtomScope.store
        let store = WorkspaceStore(
            catalogAtom: atoms.workspaceRepositoryTopology, graphAtom: atoms.workspacePane,
            interactionAtom: atoms.workspaceTabLayout)
        let pane = store.createPane(title: "Stored message proof")
        let paneId = PaneId(existingUUID: pane.id)
        let wallNow = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
        let composition: CompositionFactoryFixture
        do {
            composition = try await CompositionFactoryFixture.make(
                ownerId: paneId, wallNow: { wallNow.withLock { $0 } })
        } catch {
            store.removePane(pane.id)
            throw error
        }
        do {
            let written = try await writeStoredMessage(composition)
            let currentDate = composition.now.addingTimeInterval(messageAgeSeconds)
            wallNow.withLock { $0 = currentDate }
            let statuses = try await workingHook(composition)
            let clock = NativeCardTestClock()
            if hasActivity {
                atoms.paneActivityTime.apply([
                    .set(pane.id, .init(orderingInstant: clock.now, wallTime: currentDate, source: .terminal))
                ])
            }
            let readers = PaneContextUIReaders(
                sessionStatus: statuses, presentation: composition.presentationAtom,
                pane: { store.paneAtom.pane($0.uuid) },
                readSessionStatus: {
                    try await composition.composition.ingestion.readSessionStatus(paneId: $0.uuid)
                })
            let captured = PaneManagementIdentityCapture.input(
                context: .project(paneId: pane.id, store: store), store: store, readers: readers)
            try #require(captured.agentLine == written)
            try #require(captured.sessionPresentation?.status == .working(.active))
            try #require((captured.activityTime != nil) == hasActivity)
            return StoredMessageCardFixture(
                composition: composition, store: store, atoms: atoms, written: written,
                readers: readers, clock: clock, wallNow: currentDate)
        } catch {
            try? await composition.close()
            store.removePane(pane.id)
            throw error
        }
    }

    private static func writeStoredMessage(_ fixture: CompositionFactoryFixture) async throws -> AgentLineDetail {
        let service = fixture.composition.paneContextService
        let writer = AgentMessageSender.pane(fixture.ownerId)
        let claimed = await service.claimEpoch(
            .init(paneId: fixture.ownerId, writer: writer, stream: .line, claimId: UUIDv7.generate()))
        guard case .claimed(let epoch) = claimed else { throw StoredMessageCardFailure.missingDetail }
        try #require(
            await service.setLine(
                .init(
                    paneId: fixture.ownerId, writer: writer,
                    line: .init(summary: "Message before the current activity", refs: []),
                    writeNumber: .init(epoch: epoch, counter: 1))) == .applied)
        await fixture.composition.presentationLane.publishPending()
        return try #require(fixture.presentationAtom.value(for: fixture.ownerId)?.agentLine)
    }

    private static func workingHook(_ fixture: CompositionFactoryFixture) async throws -> SessionStatusAtom {
        let binding = try await fixture.bind(paneId: fixture.ownerId)
        let result = try await fixture.composition.liveSessionsAdapter.recordProviderEvent(
            paneId: fixture.ownerId.uuid,
            params: .init(
                handle: fixture.ownerId.uuidString,
                provider: .init(
                    identifier: binding.providerIdentifier, version: ClaudeCodeProviderIdentity.supportedExactVersion,
                    mode: ClaudeCodeProviderIdentity.operatingMode),
                event: .init(
                    name: .turnStart, conversationId: binding.providerConversationId, turnId: nil,
                    requestId: nil, toolId: nil, subagentId: nil, occurrenceId: UUIDv7.generate()),
                correlationId: UUIDv7.generate()), provenance: .matchingPane)
        try #require(result.disposition == .admitted)
        let statuses = SessionStatusAtom()
        let mailbox = await fixture.composition.ingestion.statusPublicationMailbox
        statuses.apply(mailbox.takeBatch())
        return statuses
    }

    func hide() {
        host.rootView = AnyView(EmptyView())
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
    }

    func close() async throws {
        window.contentView = nil
        window.close()
        atoms.paneActivityTime.apply([.remove(context.paneId)])
        store.removePane(context.paneId)
        try await composition.close()
    }

    func expectRendered(age: String, activity: String?) throws {
        try PaneIdentityCardFixture.expectContained(in: host)
        let rendering = PaneContextToolbarRenderingTests()
        let labels = rendering.accessibilityLabels(in: host)
        #expect(labels.contains { $0.contains("Working") })
        #expect(labels.contains(age), "The native age value must match exactly as well as visibly paint")
        let reference = rendering.mountCard(
            AnyView(
                Text(age).font(.system(size: AppStyles.Shell.Sidebar.branchFontSize)).foregroundStyle(Color.secondary)
                    .fixedSize()), width: nil)
        defer { reference.window.close() }
        let needle = try rendering.ink(in: reference.host, minimumBrightness: 60)
        #expect(needle.mask.contains(true))
        #expect(
            rendering.containsTextInk(needle, in: try rendering.ink(in: host, minimumBrightness: 60)),
            "The stored message's complete literal age must paint in the actual mounted card")
        if let activity {
            #expect(labels.contains("ACTIVE \(activity)"))
            let activityReference = rendering.mountCard(
                AnyView(
                    Text(activity)
                        .font(.system(size: AppStyles.Shell.Sidebar.branchFontSize)).fixedSize()), width: nil)
            defer { activityReference.window.close() }
            let activityNeedle = try rendering.ink(in: activityReference.host, minimumBrightness: 60)
            #expect(activityNeedle.mask.contains(true))
            #expect(
                rendering.containsTextInk(activityNeedle, in: try rendering.ink(in: host, minimumBrightness: 60)),
                "The ACTIVE metadata age must paint independently of the Agent Line age")
        } else {
            #expect(PaneIdentityCardFixture.frames(in: host)["activity"] == nil)
        }
    }
}
