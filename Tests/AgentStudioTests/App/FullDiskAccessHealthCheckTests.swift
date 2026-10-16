import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioInfrastructure

@MainActor
@Suite("FullDiskAccessHealthCheck")
struct FullDiskAccessHealthCheckTests {
    @Test
    func deniedProtectedDataDoesNotCreateRetiredInboxNotification() {
        let appDelegate = makeAppDelegate()
        let result = FullDiskAccessHealthCheckResult(
            protectedData: Self.outcome(.deniedEPERM)
        )

        appDelegate.applyFullDiskAccessHealthCheckResult(result)

        #expect(appDelegate.atomStore.inboxNotification.notifications.isEmpty)
    }

    @Test
    func protectedDataGrantDoesNotAppendWarning() {
        let appDelegate = makeAppDelegate()
        let result = FullDiskAccessHealthCheckResult(
            protectedData: Self.outcome(.granted)
        )

        appDelegate.applyFullDiskAccessHealthCheckResult(result)

        #expect(appDelegate.atomStore.inboxNotification.notifications.isEmpty)
        #expect(result.isHealthy == true)
    }

    @Test
    func healthyResultDoesNotMutateDormantInboxHistory() throws {
        let appDelegate = makeAppDelegate()
        let notificationsBefore = appDelegate.atomStore.inboxNotification.notifications

        appDelegate.applyFullDiskAccessHealthCheckResult(
            FullDiskAccessHealthCheckResult(
                protectedData: Self.outcome(.granted)
            ))

        #expect(appDelegate.atomStore.inboxNotification.notifications == notificationsBefore)
    }

    @Test
    func helperUsesInjectedProbe() {
        let result = FullDiskAccessHealthCheck.evaluate {
            FullDiskAccessHealthCheckResult(
                protectedData: Self.outcome(.deniedEPERM)
            )
        }

        #expect(result.protectedData.result == .deniedEPERM)
        #expect(result.isHealthy == false)
    }

    private func makeAppDelegate() -> AppDelegate {
        let traceRuntime = AgentStudioTraceRuntime(
            configuration: AgentStudioTraceConfiguration.from(environment: [
                "AGENTSTUDIO_TRACE_BACKEND": "jsonl",
                "AGENTSTUDIO_TRACE_TAGS": "off",
            ]),
            processIdentifier: 9001,
            timeUnixNano: { 1 }
        )
        let appDelegate = AppDelegate(
            traceRuntime: traceRuntime,
            startupTraceRecorder: AgentStudioStartupTraceRecorder(traceRuntime: traceRuntime)
        )
        appDelegate.atomStore = AtomRegistry()
        return appDelegate
    }

    private nonisolated static func outcome(
        _ result: AgentStudioTCCAccessProbeResult
    ) -> AgentStudioTCCAccessProbeOutcome {
        AgentStudioTCCAccessProbeOutcome(
            result: result,
            commandExitClass: Self.commandExitClass(for: result),
            rawPath: "/Users/example/Library/Messages"
        )
    }

    private nonisolated static func commandExitClass(
        for result: AgentStudioTCCAccessProbeResult
    ) -> AgentStudioTCCCommandExitClass {
        switch result {
        case .granted:
            .ok
        case .deniedEACCES, .deniedEPERM:
            .permissionDenied
        case .pathMissing:
            .unavailable
        case .timedOut:
            .timedOut
        case .unknownError:
            .unknownError
        }
    }
}
