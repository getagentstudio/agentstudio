import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Synchronization
import Testing

@testable import AgentStudio
@testable import AgentStudioCore

extension AgentStudioIPCSessionsVerticalTests {
    @Test("real pane snapshot and list read hook/terminal activity and explicit null for fresh panes")
    func activityReadsCrossTheIPCBoundary() async throws {
        let submitted = Mutex<[PaneActivityOccurrence]>([])
        let published = FactRecorder<UUID, PaneActivityTime>(
            vocabulary: .init(
                describeScope: { $0.uuidString }, describeFact: { "activity \($0.source) at \($0.wallTime)" },
                isClosing: { _, _ in false }))
        let harness = try await SessionsVerticalHarness.make(
            installActivityClock: true,
            activitySubmissionObserver: { occurrence in submitted.withLock { $0.append(occurrence) } },
            activityPublicationObserver: { batch in
                for mutation in batch {
                    if case .set(let paneId, let time) = mutation { published.append(scope: paneId, fact: time) }
                }
            })
        do {
            let freshPane = harness.commandHarness.store.createPane(title: "No activity")
            harness.commandHarness.store.appendTab(Tab(paneId: freshPane.id))
            let ownDrawer = try #require(harness.commandHarness.store.addDrawerPane(to: harness.boundPaneId))
            let admitted = try await harness.sessionEvent(
                paneId: harness.boundPaneId,
                provider: .init(identifier: "codex", version: "0.160.0", mode: "cli"),
                name: "toolActivity", conversationId: "read-back-session")
            #expect(admitted.disposition == .admitted)
            let hookTime = try await published.expectNext(
                in: harness.boundPaneId, where: { $0.source == .hook }, "hook activity published")
            let hookOccurrence = try #require(submitted.withLock { $0.first { $0.source == .hook } })
            #expect(hookTime.wallTime == hookOccurrence.wallTime)
            let terminalOccurrence = PaneActivityOccurrence(
                paneId: harness.sparePaneId, source: .terminal, orderingInstant: ContinuousClock.now,
                wallTime: Date(timeIntervalSinceReferenceDate: 12_345.5))
            let clock = try #require(harness.appDelegate.paneActivityClock)
            clock.submit(terminalOccurrence)
            try await published.expectNext(in: harness.sparePaneId, terminalOccurrence.activityTime)
            let drawerOccurrence = PaneActivityOccurrence(
                paneId: ownDrawer.id, source: .terminal, orderingInstant: ContinuousClock.now,
                wallTime: Date(timeIntervalSinceReferenceDate: 23_456.5))
            clock.submit(drawerOccurrence)
            try await published.expectNext(in: ownDrawer.id, drawerOccurrence.activityTime)
            let expected: [UUID: IPCPaneActivity] = [
                harness.boundPaneId: .init(at: hookOccurrence.wallTime, source: .hook),
                harness.sparePaneId: .init(at: terminalOccurrence.wallTime, source: .terminal),
                ownDrawer.id: .init(at: drawerOccurrence.wallTime, source: .terminal),
            ]
            for paneId in [harness.boundPaneId, harness.sparePaneId, freshPane.id, ownDrawer.id] {
                let response = try await harness.response(
                    method: "pane.snapshot", params: .object(["handle": .string(paneId.uuidString)]))
                #expect(response.error == nil)
                let data = try JSONEncoder().encode(#require(response.result))
                let snapshot = try JSONDecoder().decode(IPCPaneSnapshotResult.self, from: data)
                #expect(snapshot.pane.activity == expected[paneId])
                if paneId == freshPane.id {
                    let encoded = try #require(String(bytes: data, encoding: .utf8))
                    #expect(encoded.contains(#""activity":null"#))
                }
            }
            let own: IPCPaneSnapshotResult = try await harness.decoded(
                method: "pane.snapshot", params: .object(["handle": .string("self")]), authentication: .boundPane)
            #expect(own.pane.activity == expected[harness.boundPaneId])
            let denied = try await harness.response(
                method: "pane.snapshot", params: .object(["handle": .string(harness.sparePaneId.uuidString)]),
                authentication: .boundPane)
            #expect(denied.error != nil)
            let list: IPCPaneListResult = try await harness.decoded(method: "pane.list", params: .object([:]))
            for paneId in [harness.boundPaneId, harness.sparePaneId, freshPane.id, ownDrawer.id] {
                let pane = try #require(list.panes.first { $0.id == paneId })
                #expect(pane.activity == expected[paneId])
            }
            let agentList: IPCPaneListResult = try await harness.decoded(
                method: "pane.list", params: .object([:]), authentication: .boundPane)
            #expect(agentList.panes.map(\.id) == list.panes.map(\.id))
            for pane in agentList.panes {
                let isOwn = pane.id == harness.boundPaneId || pane.id == ownDrawer.id
                #expect(pane.activity == (isOwn ? expected[pane.id] : nil))
            }
            let drawerSnapshot: IPCPaneSnapshotResult = try await harness.decoded(
                method: "pane.snapshot", params: .object(["handle": .string(ownDrawer.id.uuidString)]),
                authentication: .boundPane)
            #expect(drawerSnapshot.pane.activity == expected[ownDrawer.id])
            let drawerList: IPCPaneListResult = try await harness.decoded(
                method: "pane.list", params: .object([:]), authentication: .pane(ownDrawer.id))
            #expect(try #require(drawerList.panes.first { $0.id == ownDrawer.id }).activity == expected[ownDrawer.id])
            #expect(try #require(drawerList.panes.first { $0.id == harness.boundPaneId }).activity == nil)
            for paneId in [harness.boundPaneId, harness.sparePaneId] {
                let tab = try #require(harness.commandHarness.store.tabs.first { $0.paneIds.contains(paneId) })
                harness.commandHarness.store.setActiveTab(tab.id)
                let current: IPCPaneSnapshotResult = try await harness.decoded(
                    method: "pane.current", params: .object([:]), authentication: .boundPane)
                #expect(current.pane.id == paneId)
                #expect(current.pane.activity == (paneId == harness.boundPaneId ? expected[paneId] : nil))
            }
            let diagnosticCurrent: IPCPaneSnapshotResult = try await harness.decoded(
                method: "pane.current", params: .object([:]))
            #expect(diagnosticCurrent.pane.activity == expected[harness.sparePaneId])
            await harness.tearDown()
            try await published.finish()
        } catch {
            await harness.tearDown()
            try? await published.finish()
            throw error
        }
    }
}
