import Foundation
import Testing

@testable import AgentStudioInfrastructure

@Suite
struct GitRefreshPerformanceWorkloadSettlementScriptTests {
    @Test("common quiescence accepts classified future Git eligibility")
    func commonQuiescenceAcceptsClassifiedFutureGitEligibility() async throws {
        let result = try await runCommonDebtSnapshot(
            metricsResponse: try makeMetricsResponse()
        )

        #expect(result.exitCode == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout.contains("ready=true"))
        #expect(result.stdout.contains("git_logical_debt=89"))
        #expect(result.stdout.contains("git_future_automatic=163"))
    }

    @Test("common quiescence rejects overdue or physical Git work")
    func commonQuiescenceRejectsOverdueOrPhysicalGitWork() async throws {
        let result = try await runCommonDebtSnapshot(
            metricsResponse: try makeMetricsResponse(overrides: [
                "overdue_deadline": 1,
                "running": 1,
            ])
        )

        #expect(result.exitCode == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout.contains("ready=false"))
        #expect(result.stdout.contains("git_overdue_deadline=1"))
        #expect(result.stdout.contains("git_running=1"))
    }

    @Test("common quiescence fails closed when one settlement field is missing")
    func commonQuiescenceFailsClosedForMissingSettlementField() async throws {
        let result = try await runCommonDebtSnapshot(
            metricsResponse: try makeMetricsResponse(omitting: ["next_deadline_ms"])
        )

        #expect(result.exitCode == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout.contains("ready=false"))
        #expect(result.stdout.contains("git_next_deadline_ms=missing"))
    }

    private let scriptPath = "scripts/verify-git-refresh-performance-workload.sh"

    private func runCommonDebtSnapshot(metricsResponse: String) async throws -> ProcessResult {
        var environment: [String: String] = [:]
        environment["AGENTSTUDIO_OBSERVABILITY_ALLOW_TEST_OVERRIDES"] = "1"
        environment["AGENTSTUDIO_PERF_ALLOW_TEST_RESPONSES"] = "1"
        environment["AGENTSTUDIO_PERF_TEST_COMMON_DEBT_SNAPSHOT"] = "1"
        environment["AGENTSTUDIO_PERF_TEST_METRICS_RESPONSE"] = metricsResponse
        return try await RunToExitProcessExecutor().execute(
            command: "/bin/bash",
            args: [scriptPath, "--prepare-only"],
            cwd: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
            environment: environment
        )
    }

    private func makeMetricsResponse(
        overrides: [String: Double] = [:],
        omitting omittedFields: Set<String> = []
    ) throws -> String {
        let gitFields: [(field: String, metric: String, value: Double)] = [
            ("logical_debt", "agentstudio_performance_git_logical_debt_count", 89),
            ("future_automatic", "agentstudio_performance_git_future_automatic_count", 163),
            ("future_failure", "agentstudio_performance_git_future_failure_count", 0),
            ("ready_pending", "agentstudio_performance_git_ready_pending_count", 0),
            ("capacity_pending", "agentstudio_performance_git_capacity_pending_count", 0),
            ("active_follow_up", "agentstudio_performance_git_active_follow_up_count", 0),
            ("unclassified_pending", "agentstudio_performance_git_unclassified_pending_count", 0),
            ("overdue_deadline", "agentstudio_performance_git_overdue_deadline_count", 0),
            ("running", "agentstudio_performance_git_logical_running_count", 0),
            ("oldest_preparation_ms", "agentstudio_performance_git_oldest_preparation_ms", 110_000),
            ("next_deadline_ms", "agentstudio_performance_git_next_deadline_ms", 10_000),
        ]
        var results: [[String: Any]] = [
            metricResult(
                name: "agentstudio_performance_filesystem_logical_debt_count",
                event: "performance.filesystem.logical_debt",
                value: 0
            ),
            metricResult(
                name: "agentstudio_performance_runtime_delivery_total_pending_count",
                event: "performance.runtime_delivery.snapshot",
                value: 0
            ),
        ]
        results.append(
            contentsOf: gitFields.compactMap { field in
                guard !omittedFields.contains(field.field) else { return nil }
                return metricResult(
                    name: field.metric,
                    event: "performance.git.logical_debt",
                    settlementField: field.field,
                    value: overrides[field.field] ?? field.value
                )
            })
        let payload: [String: Any] = [
            "status": "success",
            "data": ["result": results],
        ]
        return try #require(
            String(
                data: JSONSerialization.data(withJSONObject: payload),
                encoding: .utf8
            )
        )
    }

    private func metricResult(
        name: String,
        event: String,
        settlementField: String? = nil,
        value: Double
    ) -> [String: Any] {
        var metric = ["__name__": name, "event": event]
        metric["settlement_field"] = settlementField
        return ["metric": metric, "value": [123, String(value)]]
    }
}
