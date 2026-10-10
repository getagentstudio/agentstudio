import Foundation
import Testing

@testable import AgentStudioArchitectureLintCore

/// Permanent fixture reds for owner-local fact-sink construction and its
/// nil-path observation work. The implementation lives in ArchitectureLint;
/// these tests make the contract fail until the rule is registered.
@MainActor
@Suite(.serialized)
struct OwnerFactSinkBoundaryRuleTests {
    private static let ruleID = "agentstudio_owner_fact_sink_boundary"

    @Test("F1 reports a pipeline forwarding the projector's owner-local sink")
    func filesystemGitPipelineCannotForwardProjectorFactSink() throws {
        let diagnostics = try findings(in: "BadFilesystemGitPipelineFactSink.swift")

        #expect(
            diagnostics.contains { $0.message.contains("forward") },
            "Expected the sink-forwarding diagnostic; it is absent from the current rule registry."
        )
    }

    @Test("G1 reports fact scope and payload preparation outside the nil gate")
    func gitProjectorFactScopeAndPayloadFollowNilGate() throws {
        let diagnostics = try findings(in: "BadGitProjectorFactPreparation.swift")

        #expect(
            diagnostics.contains { $0.message.contains("scope") || $0.message.contains("fact-only") },
            "Expected the eager Git fact-preparation diagnostic; it is absent from the current rule registry."
        )
    }

    @Test("G1 reports direct observation-scope construction before the sink gate")
    func directGitScopeConstructionFollowsNilGate() throws {
        let diagnostics = try findings(in: "BadDirectGitProjectorScope.swift")

        #expect(
            diagnostics.contains { $0.message.contains("scope construction") },
            "Expected direct enum-case scope construction before the sink guard to be diagnosed."
        )
    }

    @Test("W1 reports a workspace receipt scope that can suppress production application")
    func workspaceCacheScopeDoesNotGatePublication() throws {
        let diagnostics = try findings(in: "BadWorkspaceCacheFactScope.swift")

        #expect(
            diagnostics.contains { $0.message.contains("scope") },
            "Expected the eager WorkspaceCache observation-scope diagnostic; it is absent from the current rule registry."
        )
    }

    @Test("S1 reports storing an observation scope with scheduler admission state")
    func schedulerAdmissionDoesNotStoreObservationScope() throws {
        let diagnostics = try findings(in: "BadSchedulerAdmissionFactScope.swift")

        #expect(
            diagnostics.contains { $0.message.contains("scope") },
            "Expected the stored scheduler fact-scope diagnostic; it is absent from the current rule registry."
        )
    }

    @Test("T1 reports terminal observation maps populated outside the sink gate")
    func terminalDeadlineMapsAreObservationOnly() throws {
        let diagnostics = try findings(in: "BadTerminalDeadlineFactState.swift")

        #expect(
            diagnostics.contains { $0.message.contains("scope") || $0.message.contains("observation") },
            "Expected the eager terminal deadline observation-state diagnostic; it is absent from the current rule registry."
        )
    }

    @Test("R1 reports RepoCache save scope and completion bookkeeping outside the sink gate")
    func repoCacheSaveScopeIsNotEager() throws {
        let diagnostics = try findings(in: "BadRepoCacheSaveFactState.swift")

        #expect(
            diagnostics.contains { $0.message.contains("scope") || $0.message.contains("fact-only") },
            "Expected the eager RepoCache fact-state diagnostic; it is absent from the current rule registry."
        )
    }

    @Test("E1 reports constructing an EntityRecency fact lane before checking the sink")
    func entityRecencyLaneIsNotEager() throws {
        let diagnostics = try findings(in: "BadEntityRecencyFactLane.swift")

        #expect(
            diagnostics.contains { $0.message.contains("fact") || $0.message.contains("sink") },
            "Expected the eager EntityRecency fact-lane diagnostic; it is absent from the current rule registry."
        )
    }

    @Test("a nil sink check does not guard scope preparation")
    func nilSinkBranchDoesNotGuardScopePreparation() throws {
        let diagnostics = try findings(in: "BadNilSinkScopeGate.swift")

        #expect(
            diagnostics.contains { $0.message.contains("scope") },
            "Expected scope preparation under a nil-sink branch to be diagnosed."
        )
    }

    @Test("owner-only sink injection and lazy observations are accepted")
    func ownerSinkAndLazyObservationAreAccepted() throws {
        let diagnostics = try LintTestSupport.lintFixtureCorpus("Good").filter {
            $0.ruleID == Self.ruleID
        }

        #expect(diagnostics.isEmpty, Comment(rawValue: diagnostics.map(\.rendered).joined()))
    }

    @Test("a Tests path with a nested Sources directory is excluded from production lint")
    func sourceNestedUnderTestsIsIgnored() throws {
        let diagnostics = try LintTestSupport.lintFixtureCorpus("Good").filter {
            $0.ruleID == Self.ruleID && $0.path.hasSuffix("GoodTestSourceIgnored.swift")
        }

        #expect(diagnostics.isEmpty, Comment(rawValue: diagnostics.map(\.rendered).joined()))
    }

    private func findings(in filename: String) throws -> [ArchitectureDiagnostic] {
        try LintTestSupport.lintFixtureCorpus("Bad").filter {
            $0.ruleID == Self.ruleID && $0.path.hasSuffix(filename)
        }
    }
}
