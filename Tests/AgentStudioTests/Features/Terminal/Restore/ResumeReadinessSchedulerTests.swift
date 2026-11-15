import AgentStudioInfrastructure
import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudioCore
@testable import AgentStudioTerminal

@MainActor
@Suite("Resume readiness scheduler", .serialized)
struct ResumeReadinessSchedulerTests {
    @Test(
        "warm and unverified members start while an earlier cold member holds no slot",
        arguments: ["warm", "unverified", "ordinary"])
    func readyMemberBypassesPendingCold(readyCase: String) async throws {
        let cold = resumeReadinessDescriptor()
        let ready = resumeReadinessDescriptor(priority: .hidden)
        let coldPlan = try resumeReadinessBasePlan(cold)
        let readyPlan = try resumeReadinessBasePlan(ready)
        let readyKind: TerminalRestoreKind =
            readyCase == "unverified"
            ? .unverified(.sessionUnresponsive, fallback: readyPlan)
            : .warm(identity: Data("live-identity".utf8), fallback: readyPlan)
        let port = try ResumeReadinessAdmissionPort(entries: [cold, ready])
        var kinds: [PaneId: TerminalRestoreKind] = [cold.paneID: .cold(coldPlan)]
        if readyCase != "ordinary" { kinds[ready.paneID] = readyKind }
        let scheduler = await resumeReadinessScheduler(entries: [cold, ready], port: port, kinds: kinds)
        #expect(await scheduler.memberState(for: cold.paneID) == .awaitingResumeReadiness)
        let mount = Task {
            let result = await scheduler.activate()
            port.producerEnded()
            return result
        }
        do {
            try await port.expectStart(ready.paneID)
            try await port.expectFinish(ready.paneID)
            #expect(port.claims == [ready.paneID])
            #expect(await scheduler.memberState(for: cold.paneID) == .awaitingResumeReadiness)
            let diagnostics = await scheduler.diagnostics()
            #expect(diagnostics.currentSimultaneousAdmissions == 0)
            await scheduler.releaseAwaitingResumeReadiness([cold.paneID: coldPlan])
            try await port.expectStart(cold.paneID)
            try await port.expectFinish(cold.paneID)
            _ = await mount.value
            #expect(port.maximumActive == 1)
            let admittedPaneIds = port.admissions.map { $0.descriptor.paneID }
            #expect(admittedPaneIds == [ready.paneID, cold.paneID])
            try await port.facts.finish()
        } catch {
            await scheduler.cancelAndReplace(with: .init())
            port.releaseAll()
            _ = await mount.value
            try? await port.facts.finish()
            throw error
        }
    }

    @Test("released cold members retain visible-first order and the single native-start cap")
    func releasedMembersAreVisibleFirst() async throws {
        let hidden = resumeReadinessDescriptor(priority: .hidden)
        let visible = resumeReadinessDescriptor(priority: .visible)
        let active = resumeReadinessDescriptor(priority: .activeVisible)
        let entries = [hidden, visible, active]
        let plans = try Dictionary(uniqueKeysWithValues: entries.map { ($0.paneID, try resumeReadinessBasePlan($0)) })
        let port = try ResumeReadinessAdmissionPort(entries: entries)
        let held = HeldStep<TerminalActivationAdmission>("first released cold native start")
        defer { held.retire() }
        port.hold(active.paneID, step: held)
        let scheduler = await resumeReadinessScheduler(
            entries: entries, port: port, kinds: plans.mapValues(TerminalRestoreKind.cold))
        let mount = Task {
            let result = await scheduler.activate()
            port.producerEnded()
            return result
        }
        do {
            await scheduler.releaseAwaitingResumeReadiness(plans)
            try await port.expectStart(active.paneID)
            #expect(try await held.firstArrival().descriptor.paneID == active.paneID)
            #expect(port.claims == [active.paneID])
            #expect(await scheduler.diagnostics().currentSimultaneousAdmissions == 1)
            held.release()
            try await port.expectFinish(active.paneID)
            for descriptor in [visible, hidden] {
                try await port.expectStart(descriptor.paneID)
                try await port.expectFinish(descriptor.paneID)
            }
            _ = await mount.value
            let admittedPaneIds = port.admissions.map { $0.descriptor.paneID }
            #expect(admittedPaneIds == [active.paneID, visible.paneID, hidden.paneID])
            #expect(port.maximumActive == 1)
            #expect(await scheduler.diagnostics().maximumSimultaneousAdmissions == 1)
            try await port.facts.finish()
        } catch {
            held.retire()
            await scheduler.cancelAndReplace(with: .init())
            port.releaseAll()
            _ = await mount.value
            try? await port.facts.finish()
            throw error
        }
    }

    @Test("release is exactly once and a duplicate cannot replace the already-decided plan")
    func duplicateReleaseIsInert() async throws {
        let descriptor = resumeReadinessDescriptor()
        let base = try resumeReadinessBasePlan(descriptor)
        let invocation = ResumeInvocation(
            provider: .codex, sessionId: try ProviderSessionId(rawValue: UUIDv7.generate().uuidString))
        let decided = TerminalColdRestorePlanBuilder.applyingResumeEvidence(
            .interruptedCandidate(invocation),
            providerIdentifier: "codex", providerSessionId: invocation.sessionId.rawValue, to: base)
        let deadline = TerminalColdRestorePlanBuilder.applyingResumeEvidence(
            .unknown(.reportsNotRead),
            providerIdentifier: "codex", providerSessionId: invocation.sessionId.rawValue, to: base)
        let port = try ResumeReadinessAdmissionPort(entries: [descriptor])
        let scheduler = await resumeReadinessScheduler(
            entries: [descriptor], port: port, kinds: [descriptor.paneID: .cold(base)])
        await scheduler.releaseAwaitingResumeReadiness([descriptor.paneID: decided])
        let installations = port.installations.count
        await scheduler.releaseAwaitingResumeReadiness([descriptor.paneID: deadline])
        _ = await scheduler.activate()
        #expect(port.admissions.count == 1)
        #expect(port.admissions.first?.restoreKind == .cold(decided))
        #expect(port.installations.count == installations)
        try await port.facts.finish()
    }

    @Test("retiring or closing a pending cold member spends no slot and ignores its late plan")
    func retirementDropsPendingMember() async throws {
        let descriptor = resumeReadinessDescriptor()
        let base = try resumeReadinessBasePlan(descriptor)
        let port = try ResumeReadinessAdmissionPort(entries: [descriptor])
        let scheduler = await resumeReadinessScheduler(
            entries: [descriptor], port: port, kinds: [descriptor.paneID: .cold(base)])
        await scheduler.retireAwaitingResumeReadiness(descriptor.paneID)
        await scheduler.releaseAwaitingResumeReadiness([descriptor.paneID: base])
        _ = await scheduler.activate()
        #expect(port.claims.isEmpty)
        #expect(port.admissions.isEmpty)
        #expect(await scheduler.diagnostics().maximumSimultaneousAdmissions == 0)
        #expect(await scheduler.memberState(for: descriptor.paneID) == .retired)
        try await port.facts.finish()
    }

    @Test("generation replacement invalidates a pending cold plan without admitting it")
    func replacedGenerationRejectsRelease() async throws {
        let descriptor = resumeReadinessDescriptor()
        let base = try resumeReadinessBasePlan(descriptor)
        let port = try ResumeReadinessAdmissionPort(entries: [descriptor])
        let scheduler = await resumeReadinessScheduler(
            entries: [descriptor], port: port, kinds: [descriptor.paneID: .cold(base)])
        let replacement = WorkspaceContentMountGeneration()
        await scheduler.cancelAndReplace(with: replacement)
        await scheduler.releaseAwaitingResumeReadiness([descriptor.paneID: base])
        _ = await scheduler.activate()
        #expect(port.claims.isEmpty)
        #expect(port.admissions.isEmpty)
        #expect(await scheduler.memberState(for: descriptor.paneID) == .cancelledReplaced(replacement: replacement))
        try await port.facts.finish()
    }
}

extension ResumeReadinessSchedulerTests {
    @Test("retirement and replacement while a decision is held cannot install a late plan", arguments: [false, true])
    func heldDecisionsCanRetireOrReplace(replace: Bool) async throws {
        let descriptor = resumeReadinessDescriptor()
        let base = try resumeReadinessBasePlan(descriptor)
        let port = try ResumeReadinessAdmissionPort(entries: [descriptor])
        let scheduler = await resumeReadinessScheduler(
            entries: [descriptor], port: port, kinds: [descriptor.paneID: .cold(base)])
        let hold = HeldStep<TerminalColdRestorePlan>("cold decision before installation")
        let release = Task {
            defer { hold.retire() }
            await scheduler.releaseAwaitingResumeReadiness([descriptor.paneID: base]) { _, plan in
                try? await hold.arrive(plan)
                return plan
            }
        }
        let mount = Task {
            let result = await scheduler.activate()
            port.producerEnded()
            return result
        }
        do {
            _ = try await hold.firstArrival()
            let replacement = WorkspaceContentMountGeneration()
            if replace {
                await scheduler.cancelAndReplace(with: replacement)
            } else {
                await scheduler.retireAwaitingResumeReadiness(descriptor.paneID)
            }
            hold.release()
            await release.value
            _ = await mount.value
            #expect(port.installations.isEmpty)
            #expect(port.claims.isEmpty)
            #expect(
                await scheduler.memberState(for: descriptor.paneID)
                    == (replace ? .cancelledReplaced(replacement: replacement) : .retired))
            try await port.facts.finish()
        } catch {
            hold.retire()
            await scheduler.cancelAndReplace(with: .init())
            await release.value
            _ = await mount.value
            try? await port.facts.finish()
            throw error
        }
    }
}
