import AgentStudioInfrastructure
import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudioCore
@testable import AgentStudioTerminal
@testable import AgentStudioTestSupport

extension E2ESerializedTests.ZmxE2ETests {
    @Test("foreground ps sees real known binaries in isolated zmx", arguments: ["claude", "codex"])
    func foregroundProbeSeesRealAgentBinary(provider: String) async throws {
        try await withRealForegroundFixture(provider: provider) { fixture in
            let result = try await fixture.probe.probeForeground(of: [fixture.sessionId])
            let snapshot = try #require(result[fixture.sessionId])
            #expect(snapshot.program == (provider == "claude" ? .claudeCode : .codex))
            #expect(snapshot.foregroundProcess != nil)
            #expect(snapshot.sessionIdentity == fixture.identity)
        }
    }

    @Test("a real agent exit with its zmx session alive records the fresh shell")
    func foregroundExitPreservesLiveSessionShell() async throws {
        try await withRealForegroundFixture { fixture in
            _ = try await fixture.initialLook()
            try await fixture.letAgentExitIntoShell()
            let next = try await fixture.nextLook(sequence: 2)
            try await fixture.facts.expectNext(in: next, .observation(.admitted))
            try await fixture.facts.expectNext(in: next, .closed(.looked))
            #expect(try await fixture.repository.load(paneId: fixture.paneId)?.program == .shell)
            #expect(await fixture.observer.currentWatch(paneId: fixture.paneId) == nil)
        }
    }

    @Test("zmx kill with no end report keeps the positive look")
    func foregroundDaemonDeathPreservesPositiveEvidence() async throws {
        try await withRealForegroundFixture { fixture in
            _ = try await fixture.initialLook()
            let previous = try await fixture.repository.load(paneId: fixture.paneId)
            try await fixture.killOwnedSession()
            let next = try await fixture.nextLook(sequence: 2)
            try await fixture.facts.expectNext(in: next, .closed(.looked))
            #expect(try await fixture.repository.load(paneId: fixture.paneId) == previous)
        }
    }

    @Test("a real agent exit while another binary takes foreground records other, never shell")
    func foregroundSuccessorProgramIsRecorded() async throws {
        try await withResumeEvidenceBackend { ownership in
            let fixture = try await ZmxForegroundFixture.make(
                ownership: ownership, provider: "claude", successorProgram: true)
            do {
                _ = try await fixture.initialLook()
                let held = HeldStep<[ZmxSessionID]>("exit look before successor takes foreground")
                defer { held.retire() }
                await fixture.probeGate.holdNext(held)
                try await fixture.letAnotherProgramTakeForeground()
                let next = try await fixture.nextLook(sequence: 2)
                _ = try await held.firstArrival()
                held.release()
                try await fixture.facts.expectNext(in: next, .observation(.admitted))
                try await fixture.facts.expectNext(in: next, .closed(.looked))
                #expect(try await fixture.repository.load(paneId: fixture.paneId)?.program == .other)
                try await fixture.closeFixture()
            } catch {
                try? await fixture.closeFixture()
                throw error
            }
        }
    }

    @Test("a real replacement under the same name cannot write for the dead incarnation")
    func foregroundSessionReplacementPreservesPositiveEvidence() async throws {
        try await withResumeEvidenceBackend { ownership in
            let fixture = try await ZmxForegroundFixture.make(ownership: ownership, provider: "claude")
            do {
                _ = try await fixture.initialLook()
                let previous = try await fixture.repository.load(paneId: fixture.paneId)
                // Hold the ordinary pull after the old agent exits; replace its endpoint
                // before releasing it. The old incarnation is the required write guard.
                let held = HeldStep<[ZmxSessionID]>("old watch pull before replacement identity")
                defer { held.retire() }
                await fixture.probeGate.holdNext(held)
                try await fixture.killOwnedSession()
                let next = try await fixture.nextLook(sequence: 2)
                #expect(try await held.firstArrival() == [fixture.sessionId])
                let replacementScript = """
                    IFS= read -r startup_probe || exit 1
                    printf '%s\\n' "$startup_probe"
                    exec /bin/sh -i
                    """
                let replacement = try await ownership.launchSession(
                    fixture.sessionId, arguments: ["/bin/sh", "-c", replacementScript])
                try await replacement.sendStartupProbe()
                _ = try await replacement.expectStartupGate()
                let replacementIdentity = try #require(
                    try await ownership.backend.observeSessionIdentity(fixture.sessionId))
                try #require(replacementIdentity != fixture.identity)
                held.release()
                try await fixture.facts.expectNext(in: next, .closed(.looked))
                #expect(try await fixture.repository.load(paneId: fixture.paneId) == previous)
                try await fixture.closeFixture()
            } catch {
                try? await fixture.closeFixture()
                throw error
            }
        }
    }

    private func withRealForegroundFixture(
        provider: String = "claude", _ operation: @escaping @Sendable (ZmxForegroundFixture) async throws -> Void
    ) async throws {
        try await withResumeEvidenceBackend { ownership in
            let fixture = try await ZmxForegroundFixture.make(ownership: ownership, provider: provider)
            do {
                try await operation(fixture)
                try await fixture.closeFixture()
            } catch {
                try? await fixture.closeFixture()
                throw error
            }
        }
    }
}
