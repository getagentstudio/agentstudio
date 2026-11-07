import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioTerminal

@MainActor
@Suite("Terminal protocol compatibility", .serialized)
struct TerminalProtocolCompatibilityTests {
    private actor Probe: ZmxSessionRestoreProbing {
        let inventory: ZmxSessionInventory
        let identity: Data?
        private(set) var observations = 0
        private(set) var backfilledVersions: [UInt8] = []

        init(inventory: ZmxSessionInventory, identity: Data? = nil) {
            self.inventory = inventory
            self.identity = identity
        }
        func discoverSessionInventory() -> ZmxSessionInventory { inventory }
        func observeSessionIdentity(_ sessionID: ZmxSessionID) -> Data? {
            observations += 1
            return identity
        }
        func backfill(_ version: UInt8) { backfilledVersions.append(version) }
    }

    @Test("a known mismatch never probes or attaches even when inventory is unavailable", arguments: [false, true])
    func mismatchWithPresentSocket(unavailable: Bool) async throws {
        let sessionID = ZmxSessionID.generateUUIDv7()
        let probe = Probe(inventory: unavailable ? .unavailable(.timedOut) : .complete([sessionID: .unresponsive]))
        let (pane, kind) = try await classify(sessionID: sessionID, probe: probe, recorded: 2, absent: false)

        guard case .incompatible(let version, _) = kind else {
            Issue.record("expected incompatible")
            return
        }
        #expect(version == 2)
        #expect(await probe.observations == 0)
        #expect(
            TerminalRestoreRuntime(sessionConfiguration: configuration).startupCommand(for: pane, kind: kind) == nil)
    }

    @Test("a mismatch with an absent socket cold restores despite unavailable inventory")
    func absentMismatchedSessionIsCold() async throws {
        let probe = Probe(inventory: .unavailable(.timedOut))
        let (_, kind) = try await classify(probe: probe, recorded: 0, absent: true)
        guard case .cold = kind else {
            Issue.record("expected cold")
            return
        }
        #expect(await probe.observations == 0)
        #expect(await probe.backfilledVersions == [1])
    }

    @Test(
        "untracked v1 identity is backfilled while an unanswered legacy session stays incompatible",
        arguments: [false, true])
    func untrackedSessionProbe(currentProtocol: Bool) async throws {
        let identity = currentProtocol ? Data("validated by the control boundary".utf8) : nil
        let probe = Probe(inventory: .unavailable(.timedOut), identity: identity)
        let (_, kind) = try await classify(probe: probe, recorded: nil, absent: false)
        #expect(await probe.observations == 1)
        if currentProtocol {
            guard case .warm(let observed, _) = kind else {
                Issue.record("expected warm")
                return
            }
            #expect(observed == identity)
            #expect(await probe.backfilledVersions == [1])
        } else {
            guard case .incompatible(let version, _) = kind else {
                Issue.record("expected incompatible")
                return
            }
            #expect(version == 0)
            #expect(await probe.backfilledVersions.isEmpty)
        }
    }

    @Test("same protocol retains ordinary warm classification")
    func matchingVersionStaysWarm() async throws {
        let sessionID = ZmxSessionID.generateUUIDv7()
        let probe = Probe(inventory: .complete([sessionID: .alive(wrapperPid: 42)]), identity: Data([1, 2, 3]))
        let (_, kind) = try await classify(sessionID: sessionID, probe: probe, recorded: 1, absent: false)
        guard case .warm(let observed, _) = kind else {
            Issue.record("expected warm")
            return
        }
        #expect(observed == Data([1, 2, 3]))
        #expect(await probe.backfilledVersions.isEmpty)
    }

    private func classify(
        sessionID: ZmxSessionID = .generateUUIDv7(), probe: Probe, recorded: UInt8?, absent: Bool
    ) async throws -> (Pane, TerminalRestoreKind) {
        let pane = Pane(
            content: .terminal(.init(provider: .zmx, lifetime: .persistent, zmxSessionID: sessionID)),
            metadata: PaneMetadata(title: "Compatibility"))
        let resolver = TerminalRestoreKindResolver(
            sessionConfiguration: configuration, probe: probe,
            scrollbackStore: ScrollbackStore(
                directoryURL: FileManager.default.temporaryDirectory.appending(path: UUIDv7.generate().uuidString)),
            repositoryMainFolder: { _ in nil }, recordedProtocol: { _ in recorded },
            recordProtocol: { _, version in await probe.backfill(version) }, endpointIsAbsent: { _ in absent })
        let kinds = await resolver.resolveRestoreKinds(for: [
            TerminalActivationDescriptor(
                pane: pane, visibilityPriority: .activeVisible, hostPlacement: .tab(tabID: UUIDv7.generate()))
        ])
        return (pane, try #require(kinds[PaneId(existingUUID: pane.id)]))
    }

    private var configuration: SessionConfiguration {
        SessionConfiguration.detect(
            environment: [
                "AGENTSTUDIO_DATA_DIR": "/tmp/protocol-compatibility", "AGENTSTUDIO_SESSION_RESTORE": "true",
                "AGENTSTUDIO_TRACE_PROOF_TOKEN": "protocol-compatibility", "AGENTSTUDIO_ZMX_PATH": "/usr/bin/true",
            ], isDebugBuild: true)
    }
}
