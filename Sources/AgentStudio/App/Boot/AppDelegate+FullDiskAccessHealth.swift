import AgentStudioInfrastructure
import Foundation

struct FullDiskAccessHealthCheckResult: Equatable, Sendable {
    let protectedData: AgentStudioTCCAccessProbeOutcome

    var isHealthy: Bool {
        protectedData.result == .granted
    }
}

enum FullDiskAccessHealthCheck {
    typealias Probe = @Sendable () -> FullDiskAccessHealthCheckResult

    static func evaluate(
        probe: Probe = {
            FullDiskAccessHealthCheckResult(
                protectedData: AgentStudioTCCDiagnosticRecorder.shellChildMessagesDataDirectoryProbe()
            )
        }
    ) -> FullDiskAccessHealthCheckResult {
        probe()
    }
}

extension AppDelegate {
    func scheduleFullDiskAccessHealthCheck(
        probe: @escaping FullDiskAccessHealthCheck.Probe = { FullDiskAccessHealthCheck.evaluate() }
    ) {
        Task { @MainActor [weak self] in
            // Full Disk Access probing launches a shell child; keep it off the MainActor.
            // swiftlint:disable:next no_task_detached
            let result = await Task.detached(priority: .background) {
                probe()
            }.value
            self?.applyFullDiskAccessHealthCheckResult(result)
        }
    }

    func applyFullDiskAccessHealthCheckResult(_ result: FullDiskAccessHealthCheckResult) {
        recordFullDiskAccessHealthCheck(result)
    }

    private func recordFullDiskAccessHealthCheck(_ result: FullDiskAccessHealthCheckResult) {
        startupTraceRecorder.recordAppStartup(
            "app.full_disk_access.health_check.completed",
            phase: "full_disk_access_health_check",
            outcome: result.isHealthy ? "healthy" : "blocked",
            attributes: [
                "agentstudio.full_disk_access.health.healthy": .bool(result.isHealthy),
                "agentstudio.tcc.access.target": .string(AgentStudioTCCAccessTarget.messagesData.rawValue),
                "agentstudio.tcc.access.result": .string(result.protectedData.result.rawValue),
                "agentstudio.tcc.command.exit_class": .string(result.protectedData.commandExitClass.rawValue),
            ]
        )
    }
}
