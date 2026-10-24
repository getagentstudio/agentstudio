import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioTerminal

@MainActor
@Suite("Scrollback in cold and fallback restore plans", .serialized)
struct ScrollbackRestoreFallbackTests {
    @Test(
        "every decided restore kind carries validated replay or the no-output notice",
        arguments: Classification.allCases, [true, false])
    func replayIsIncludedInEveryRestoreKind(classification: Classification, hasSnapshot: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "scrollback-fallback-\(UUIDv7.generate().uuidString)")
        let store = ScrollbackStore(directoryURL: root)
        let sessionID = ZmxSessionID.generateUUIDv7()
        let pane = Pane(
            id: UUIDv7.generate(),
            content: .terminal(TerminalState(provider: .zmx, lifetime: .persistent, zmxSessionID: sessionID)),
            metadata: PaneMetadata(launchDirectory: URL(fileURLWithPath: "/tmp"), title: "Fallback replay"))
        let paneID = PaneId(existingUUID: pane.id)
        var bodyError: (any Error)?
        do {
            if hasSnapshot { _ = try await store.store(paneId: paneID, capture: Data("fallback output\r\n".utf8)) }
            let configuration = SessionConfiguration.detect(
                environment: [
                    "AGENTSTUDIO_DATA_DIR": root.path, "AGENTSTUDIO_SESSION_RESTORE": "true",
                    "AGENTSTUDIO_TRACE_PROOF_TOKEN": "scrollback-fallback-test",
                    "AGENTSTUDIO_ZMX_PATH": "/usr/bin/true",
                ], isDebugBuild: true)
            let resolver = TerminalRestoreKindResolver(
                sessionConfiguration: configuration,
                probe: ReplayClassificationProbe(classification: classification, sessionID: sessionID),
                scrollbackStore: store,
                repositoryMainFolder: { _ in nil })
            let kinds = await resolver.resolveRestoreKinds(for: [
                TerminalActivationDescriptor(
                    pane: pane,
                    visibilityPriority: .activeVisible, hostPlacement: .tab(tabID: UUIDv7.generate()))
            ])
            let kind = try #require(kinds[paneID])
            let plan: TerminalColdRestorePlan
            switch kind {
            case .cold(let cold):
                #expect(classification == .cold)
                plan = cold
            case .warm(_, let fallback):
                #expect(classification == .warm)
                plan = fallback
            case .unverified(_, let fallback):
                #expect(classification != .cold && classification != .warm)
                plan = fallback
            }
            #expect(plan.replayFile == (hasSnapshot ? store.snapshotURL(for: paneID) : nil))
            #expect(plan.notice.linesByCandidateIndex.allSatisfy { $0.contains("no saved output") == !hasSnapshot })
            for line in plan.notice.linesByCandidateIndex {
                let components = line.components(separatedBy: "\n")
                #expect(components.first?.hasPrefix("Restored after restart") == true)
                if !hasSnapshot { #expect(components.dropFirst().contains("no saved output")) }
            }
            #expect(plan.sessionID == sessionID)
        } catch { bodyError = error }
        try await withoutBlockingCooperativePool {
            if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
        }
        if let bodyError { throw bodyError }
    }

    enum Classification: CaseIterable, Equatable, Sendable {
        case cold, warm, unresponsive, unavailable, identityUnavailable
    }
}

private struct ReplayClassificationProbe: ZmxSessionRestoreProbing {
    let classification: ScrollbackRestoreFallbackTests.Classification
    let sessionID: ZmxSessionID

    func discoverSessionInventory() async -> ZmxSessionInventory {
        switch classification {
        case .cold: .complete([:])
        case .warm, .identityUnavailable: .complete([sessionID: .alive(wrapperPid: 1)])
        case .unresponsive: .complete([sessionID: .unresponsive])
        case .unavailable: .unavailable(.timedOut)
        }
    }

    func observeSessionIdentity(_ sessionID: ZmxSessionID) async throws -> Data? {
        classification == .warm ? Data([1, 2, 3]) : nil
    }
}
