import Foundation
import Testing

@testable import AgentStudioInfrastructure

@Suite
struct AgentStudioOTLPGitWorktreeProjectionTests {
    @Test
    func gitStatusProjectionKeepsRecordedWorktreeHashAndRetainsRawIdentity() {
        // R10: synthetic raw fields bypass Sources/AgentStudio/Core/RuntimeEventSystem/Git/GitWorkingDirectoryProjector+TraceAttributes.swift:7: git status emits attribution/counts, never message text.
        let worktreeID = UUID(uuidString: "C994D680-2BFD-4D60-9070-2BD76D3971EE")!
        let rawRootPath = "/Users/shravan/private/repo"
        let record = AgentStudioTraceRecord(
            timeUnixNano: 500,
            severityText: .info,
            body: "performance.git.status",
            traceID: nil,
            spanID: nil,
            parentSpanID: nil,
            resource: [
                "dev.repo.hash": "repo-hash",
                "dev.worktree.hash": "worktree-hash",
                "service.name": "AgentStudio",
            ],
            scope: .init(name: "agentstudio.performance", version: "0.1.0"),
            attributes: [
                "agentstudio.performance.git.demand_class": .string("open_pane"),
                "agentstudio.performance.git.trigger_source": .string("filesystem_change"),
                "agentstudio.performance.git.cadence_tier": .string("open_pane"),
                "agentstudio.performance.git.visibility_admission.outcome": .string("tier_deferred"),
                "agentstudio.performance.git.request.sequence": .int(42),
                "agentstudio.performance.git.status_scope": .string("full"),
                "agentstudio.performance.git.root_path": .string(rawRootPath),
                "agentstudio.worktree.id": .string(worktreeID.uuidString),
            ]
        )

        let projection = OTLPProjectionAssertions.project(record)

        #expect(projection.resource["dev.worktree.hash"] == "worktree-hash")
        #expect(projection.attributes["dev.worktree.hash"] == .string("worktree-hash"))
        #expect(projection.attributes["agentstudio.performance.git.demand_class"] == .string("open_pane"))
        #expect(projection.attributes["agentstudio.performance.git.trigger_source"] == .string("filesystem_change"))
        #expect(projection.attributes["agentstudio.performance.git.cadence_tier"] == .string("open_pane"))
        #expect(
            projection.attributes["agentstudio.performance.git.visibility_admission.outcome"]
                == .string("tier_deferred")
        )
        #expect(projection.attributes["agentstudio.performance.git.request.sequence"] == .int(42))
        #expect(projection.attributes["agentstudio.worktree.id"] != nil)
        #expect(projection.attributes["agentstudio.performance.git.root_path"] != nil)
    }

    @Test
    func gitProjectionRetainsUnboundedAttributionValues() {
        // R10: synthetic raw fields bypass Sources/AgentStudio/Core/RuntimeEventSystem/Git/GitWorkingDirectoryProjector+TraceAttributes.swift:7: git status emits attribution/counts, never message text.
        let record = AgentStudioTraceRecord(
            timeUnixNano: 501,
            severityText: .info,
            body: "performance.git.admission",
            traceID: nil,
            spanID: nil,
            parentSpanID: nil,
            resource: ["service.name": "AgentStudio"],
            scope: .init(name: "agentstudio.performance", version: "0.1.0"),
            attributes: [
                "agentstudio.performance.git.demand_class": .string("/private/demand"),
                "agentstudio.performance.git.trigger_source": .string("private-trigger"),
                "agentstudio.performance.git.cadence_tier": .string("99"),
                "agentstudio.performance.git.visibility_admission.outcome": .string("private-outcome"),
            ]
        )

        let projection = OTLPProjectionAssertions.project(record)

        #expect(projection.attributes["agentstudio.performance.git.demand_class"] != nil)
        #expect(projection.attributes["agentstudio.performance.git.trigger_source"] != nil)
        #expect(projection.attributes["agentstudio.performance.git.cadence_tier"] != nil)
        #expect(projection.attributes["agentstudio.performance.git.visibility_admission.outcome"] != nil)
    }

    @Test(
        "git projection keeps bounded named cadence tiers",
        arguments: ["active_pane", "visible_sidebar", "open_pane", "background"]
    )
    func gitProjectionKeepsBoundedNamedCadenceTier(cadenceTier: String) {
        // R10: synthetic raw fields bypass Sources/AgentStudio/Core/RuntimeEventSystem/Git/GitWorkingDirectoryProjector+TraceAttributes.swift:7: git status emits attribution/counts, never message text.
        let record = AgentStudioTraceRecord(
            timeUnixNano: 502,
            severityText: .info,
            body: "performance.git.admission",
            traceID: nil,
            spanID: nil,
            parentSpanID: nil,
            resource: ["service.name": "AgentStudio"],
            scope: .init(name: "agentstudio.performance", version: "0.1.0"),
            attributes: [
                "agentstudio.performance.git.cadence_tier": .string(cadenceTier)
            ]
        )

        let projection = OTLPProjectionAssertions.project(record)

        #expect(projection.attributes["agentstudio.performance.git.cadence_tier"] == .string(cadenceTier))
    }

    @Test(
        "git projection keeps every bounded refresh trigger",
        arguments: [
            "registration", "filesystem_change", "periodic", "visibility_change",
            "remote_reference_refresh", "retry",
        ]
    )
    func gitProjectionKeepsBoundedRefreshTrigger(triggerSource: String) {
        // R10: synthetic raw fields bypass Sources/AgentStudio/Core/RuntimeEventSystem/Git/GitWorkingDirectoryProjector+TraceAttributes.swift:7: git status emits attribution/counts, never message text.
        let record = AgentStudioTraceRecord(
            timeUnixNano: 503,
            severityText: .info,
            body: "performance.git.status",
            traceID: nil,
            spanID: nil,
            parentSpanID: nil,
            resource: ["service.name": "AgentStudio"],
            scope: .init(name: "agentstudio.performance", version: "0.1.0"),
            attributes: [
                "agentstudio.performance.git.trigger_source": .string(triggerSource)
            ]
        )

        let projection = OTLPProjectionAssertions.project(record)

        #expect(
            projection.attributes["agentstudio.performance.git.trigger_source"]
                == .string(triggerSource)
        )
    }
}

extension AgentStudioOTLPProjectedLogRecord {
    fileprivate func renderedForGitWorktreeAssertions() -> String {
        [
            body,
            resource.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "),
            attributes.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "),
        ]
        .joined(separator: "\n")
    }
}
