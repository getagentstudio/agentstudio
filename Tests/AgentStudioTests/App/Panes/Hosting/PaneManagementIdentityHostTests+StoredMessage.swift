import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioRepoExplorer
import AgentStudioSharedComponents
import AgentStudioTestSupport
import AppKit
import Foundation
import SwiftUI
import Synchronization
import Testing

@testable import AgentStudio
@testable import AgentStudioSessions

extension PaneManagementIdentityHostTests {
    @Test("G11 the production card paints an eight-day-old stored Agent Line and schedules tomorrow")
    func eightDayStoredLineReachesNativeCard() async throws {
        let fixture = try await StoredMessageCardFixture.make(hasActivity: false, messageAgeSeconds: 8 * 86_400)
        do {
            try fixture.expectRendered(age: "[8 days ago]", activity: nil)
            let start = fixture.rendering.clock.now
            fixture.composition.statements.begin()
            try await fixture.rendering.advance(
                by: .seconds(86_400), registeredAt: start.advanced(by: .seconds(86_400)))
            try fixture.expectRendered(age: "[9 days ago]", activity: nil)
            #expect(fixture.composition.statements.end().isEmpty, "A card age tick must not read or write SQL")
            try await fixture.expectStoredUnchanged()
            try await fixture.rendering.hide()
            try await fixture.close()
        } catch {
            _ = fixture.composition.statements.end()
            try? await fixture.close()
            throw error
        }
    }

    @Test(
        "a real stored message and Working hook reach the same visible card across their own deadlines",
        arguments: [false, true])
    func storedMessageAndHookReachVisibleCard(hasActivity: Bool) async throws {
        let fixture = try await StoredMessageCardFixture.make(hasActivity: hasActivity)
        let clock = fixture.rendering.clock
        let start = clock.now
        do {
            try fixture.expectRendered(age: "[2 min ago]", activity: hasActivity ? "Now" : nil)
            let identity = ObjectIdentifier(fixture.host)
            fixture.composition.statements.begin()
            try await fixture.rendering.advance(by: .seconds(55), registeredAt: start.advanced(by: .seconds(55)))
            try fixture.expectRendered(age: "[3 min ago]", activity: hasActivity ? "Now" : nil)
            #expect(ObjectIdentifier(fixture.host) == identity)
            if hasActivity {
                // The55s message tick makes the60s activity boundary eligible at65s (§12.1).
                try await fixture.rendering.advance(by: .seconds(10), registeredAt: start.advanced(by: .seconds(65)))
                try fixture.expectRendered(age: "[3 min ago]", activity: "1 min ago")
            }
            try await fixture.rendering.advance(
                by: .seconds(hasActivity ? 3535 : 3545),
                registeredAt: start.advanced(by: .seconds(115)))
            try fixture.expectRendered(age: "[1 hr ago]", activity: hasActivity ? "1 hr ago" : nil)
            try await fixture.rendering.advance(by: .seconds(82_800), registeredAt: start.advanced(by: .seconds(7075)))
            try fixture.expectRendered(age: "[1 day ago]", activity: hasActivity ? "1 day ago" : nil)
            try await fixture.rendering.advance(
                by: .seconds(86_400), registeredAt: start.advanced(by: .seconds(172_675)))
            try fixture.expectRendered(age: "[2 days ago]", activity: hasActivity ? "2 days ago" : nil)
            #expect(ObjectIdentifier(fixture.host) == identity)
            #expect(fixture.composition.statements.end().isEmpty, "Independent card ages must remain SQL-silent")
            try await fixture.expectStoredUnchanged()
            try await fixture.rendering.hide()
            try await fixture.close()
        } catch {
            _ = fixture.composition.statements.end()
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
    let rendering: PaneManagementPreparedCardHarness
    private let atoms: CoreAtoms
    private var closed = false
    var host: NSHostingView<AnyView> { rendering.host }

    private init(
        composition: CompositionFactoryFixture, store: WorkspaceStore, atoms: CoreAtoms,
        written: AgentLineDetail, rendering: PaneManagementPreparedCardHarness
    ) {
        self.composition = composition
        self.store = store
        self.atoms = atoms
        self.written = written
        self.rendering = rendering
        context = .project(paneId: composition.ownerId.uuid, store: store)
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
        var mounted: PaneManagementPreparedCardHarness?
        do {
            let written = try await writeStoredMessage(composition)
            let currentDate = composition.now.addingTimeInterval(messageAgeSeconds)
            wallNow.withLock { $0 = currentDate }
            let statuses = try await workingHook(composition)
            if hasActivity {
                atoms.paneActivityTime.apply([
                    .set(pane.id, .init(orderingInstant: .now, wallTime: currentDate, source: .terminal))
                ])
            }
            let ingestion = composition.composition.ingestion
            let adapter = PaneContextUIAdapter(
                service: composition.composition.paneContextService,
                readLiveSession: { pane in
                    guard let result = try? await ingestion.readSessionStatus(paneId: pane.uuid),
                        case .live(let summary) = result
                    else { return nil }
                    return summary
                })
            var owners = PaneContextTestSourceOwners(
                sessionStatus: statuses, presentation: composition.presentationAtom,
                pane: { store.paneAtom.pane($0.uuid) }, serviceProvider: { adapter })
            owners.activity = { atoms.paneActivityTime.value(for: $0.uuid) }
            try #require(composition.presentationAtom.value(for: paneId)?.agentLine == written)
            try #require(statuses.value(for: paneId)?.status == .working(.active))
            try #require((atoms.paneActivityTime.value(for: pane.id) != nil) == hasActivity)
            let rendering = try await PaneManagementPreparedCardHarness(
                context: .project(paneId: pane.id, store: store),
                owners: owners, wallNow: currentDate, height: 360)
            mounted = rendering
            try await rendering.open()
            return StoredMessageCardFixture(
                composition: composition, store: store, atoms: atoms,
                written: written, rendering: rendering)
        } catch {
            try? await mounted?.close()
            try? await composition.close()
            atoms.paneActivityTime.apply([.remove(pane.id)])
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

    func expectStoredUnchanged() async throws {
        let read = await composition.composition.paneContextService.readDetail(
            .init(paneId: composition.ownerId, page: .first))
        guard case .detail(let detail) = read else { throw StoredMessageCardFailure.missingDetail }
        #expect(detail.agentLine == written)
        #expect(written.summary == "Message before the current activity")
        #expect(written.updatedAt == Date(timeIntervalSince1970: 1_800_000_000))
    }
    func close() async throws {
        guard !closed else { return }
        closed = true
        do {
            try await rendering.close()
            atoms.paneActivityTime.apply([.remove(context.paneId)])
            store.removePane(context.paneId)
            try await composition.close()
        } catch {
            atoms.paneActivityTime.apply([.remove(context.paneId)])
            store.removePane(context.paneId)
            try? await composition.close()
            throw error
        }
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
