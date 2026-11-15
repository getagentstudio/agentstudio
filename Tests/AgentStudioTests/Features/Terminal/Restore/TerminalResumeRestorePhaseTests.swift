import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioCore
@testable import AgentStudioTerminal

@Suite("Terminal resume restore phase")
struct TerminalResumeRestorePhaseTests {
    @Test("a matching resumed provider start supplies the current generation for ordered phase end")
    func matchingStartEndsThroughOrderedIngress() async throws {
        let projector = TerminalActivityProjector()
        let paneId = UUIDv7.generate()
        let surfaceId = UUIDv7.generate()
        let generation = RestoreGeneration(rawValue: 1)
        let id = UUIDv7.generate().uuidString
        let invocation = ResumeInvocation(provider: .codex, sessionId: try ProviderSessionId(rawValue: id))
        await projector.armRestorePhase(paneID: paneId, generation: generation, resumeInvocation: invocation)
        let matching = try #require(
            await projector.claimMatchingResumeRestoreGeneration(
                paneID: paneId, providerIdentifier: "codex", providerSessionID: id))
        let matchedGeneration = try #require(await matching.withCurrentGeneration { $0 })
        #expect(matchedGeneration == generation)
        #expect(await projector.isRestorePhaseActive(paneID: paneId))
        await projector.applyOrderedControl(
            surfaceID: surfaceId, paneID: paneId, precedingAggregate: nil,
            control: .restorePhaseEnded(matchedGeneration))
        #expect(await projector.isRestorePhaseActive(paneID: paneId) == false)
        #expect(
            await projector.claimMatchingResumeRestoreGeneration(
                paneID: paneId,
                providerIdentifier: "codex", providerSessionID: id) == nil)
        await projector.reset()
    }

    @Test(
        "a start for another provider, session or pane cannot end the resume phase",
        arguments: ["provider", "session", "pane"])
    func foreignStartCannotMatch(difference: String) async throws {
        let projector = TerminalActivityProjector()
        let paneId = UUIDv7.generate()
        let id = UUIDv7.generate().uuidString
        let invocation = ResumeInvocation(provider: .codex, sessionId: try ProviderSessionId(rawValue: id))
        await projector.armRestorePhase(paneID: paneId, generation: .init(rawValue: 1), resumeInvocation: invocation)
        #expect(
            await projector.claimMatchingResumeRestoreGeneration(
                paneID: difference == "pane" ? UUIDv7.generate() : paneId,
                providerIdentifier: difference == "provider" ? "claude-code" : "codex",
                providerSessionID: difference == "session" ? UUIDv7.generate().uuidString : id) == nil)
        #expect(await projector.isRestorePhaseActive(paneID: paneId))
        await projector.reset()
    }

    @Test("a replacement generation forgets the old resume id and only its own start matches")
    func newGenerationOwnsItsSessionId() async throws {
        let projector = TerminalActivityProjector()
        let paneId = UUIDv7.generate()
        let oldId = UUIDv7.generate().uuidString
        let newId = UUIDv7.generate().uuidString
        await projector.armRestorePhase(
            paneID: paneId, generation: .init(rawValue: 1),
            resumeInvocation: .init(provider: .codex, sessionId: try ProviderSessionId(rawValue: oldId)))
        await projector.armRestorePhase(
            paneID: paneId, generation: .init(rawValue: 2),
            resumeInvocation: .init(provider: .codex, sessionId: try ProviderSessionId(rawValue: newId)))
        #expect(
            await projector.claimMatchingResumeRestoreGeneration(
                paneID: paneId, providerIdentifier: "codex", providerSessionID: oldId) == nil)
        let newMatch = await projector.claimMatchingResumeRestoreGeneration(
            paneID: paneId, providerIdentifier: "codex", providerSessionID: newId)
        #expect(await newMatch?.withCurrentGeneration { $0 } == RestoreGeneration(rawValue: 2))
        await projector.reset()
    }

    @Test("a plain shell restore has no matching resume start even for a valid provider id")
    func shellPhaseHasNoResumeMatch() async {
        let projector = TerminalActivityProjector()
        let paneId = UUIDv7.generate()
        await projector.armRestorePhase(paneID: paneId, generation: .init(rawValue: 1))
        #expect(
            await projector.claimMatchingResumeRestoreGeneration(
                paneID: paneId,
                providerIdentifier: "codex", providerSessionID: UUIDv7.generate().uuidString) == nil)
        #expect(await projector.isRestorePhaseActive(paneID: paneId))
        await projector.reset()
    }
    @Test("a match is claimed once before drain completion and rearming replaces that claim")
    func pendingEndDeduplicatesAndRearmResetsMatch() async throws {
        let projector = TerminalActivityProjector()
        let pane = UUIDv7.generate()
        let id = UUIDv7.generate().uuidString
        let invocation = ResumeInvocation(provider: .codex, sessionId: try .init(rawValue: id))
        await projector.armRestorePhase(paneID: pane, generation: .init(rawValue: 1), resumeInvocation: invocation)
        let firstMatch = await projector.claimMatchingResumeRestoreGeneration(
            paneID: pane, providerIdentifier: "codex", providerSessionID: id)
        #expect(await firstMatch?.withCurrentGeneration { $0 } == .init(rawValue: 1))
        #expect(
            await projector.claimMatchingResumeRestoreGeneration(
                paneID: pane, providerIdentifier: "codex", providerSessionID: id) == nil)
        #expect(await projector.isRestorePhaseActive(paneID: pane))
        await projector.armRestorePhase(paneID: pane, generation: .init(rawValue: 2), resumeInvocation: invocation)
        #expect(!(await projector.endRestorePhase(paneID: pane, generation: .init(rawValue: 1))))
        #expect(await firstMatch?.withCurrentGeneration { $0 } == nil)
        let nextMatch = await projector.claimMatchingResumeRestoreGeneration(
            paneID: pane, providerIdentifier: "codex", providerSessionID: id)
        #expect(await nextMatch?.withCurrentGeneration { $0 } == .init(rawValue: 2))
        await projector.retirePanePermanently(paneID: pane)
        #expect(!(await projector.isRestorePhaseActive(paneID: pane)))
        #expect(
            await projector.claimMatchingResumeRestoreGeneration(
                paneID: pane, providerIdentifier: "codex", providerSessionID: id) == nil)
        await projector.reset()
    }

    @Test("retained matches are invalidated by every arm lifetime end", arguments: RestoreMatchInvalidation.allCases)
    func retainedClaimCannotApplyAfterInvalidation(invalidation: RestoreMatchInvalidation) async throws {
        let projector = TerminalActivityProjector()
        let pane = UUIDv7.generate()
        let session = UUIDv7.generate().uuidString
        await projector.armRestorePhase(
            paneID: pane, generation: .init(rawValue: 1),
            resumeInvocation: .init(provider: .codex, sessionId: try .init(rawValue: session)))
        let matched = try #require(
            await projector.claimMatchingResumeRestoreGeneration(
                paneID: pane, providerIdentifier: "codex", providerSessionID: session))
        switch invalidation {
        case .ended: _ = await projector.endRestorePhase(paneID: pane, generation: .init(rawValue: 1))
        case .retired: await projector.retirePanePermanently(paneID: pane)
        case .reset: await projector.reset()
        case .rearmed: await projector.armRestorePhase(paneID: pane, generation: .init(rawValue: 2))
        }
        #expect(await matched.withCurrentGeneration { _ in true } == nil)
        await projector.reset()
    }

}

enum RestoreMatchInvalidation: CaseIterable, Sendable { case ended, retired, reset, rearmed }
