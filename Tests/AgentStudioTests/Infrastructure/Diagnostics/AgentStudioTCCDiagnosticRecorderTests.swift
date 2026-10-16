import Darwin
import Foundation
import Testing

@testable import AgentStudioInfrastructure

@Suite
struct AgentStudioTCCDiagnosticRecorderTests {
    @Test
    func recorderEmitsAccessProbeAndIdentitySnapshots() async throws {
        let runtime = AgentStudioTraceRuntime(
            configuration: AgentStudioTraceConfiguration.from(environment: [
                "AGENTSTUDIO_TRACE_BACKEND": "jsonl",
                "AGENTSTUDIO_TRACE_DIR": temporaryTraceDirectoryURL().path,
                "AGENTSTUDIO_TRACE_TAGS": "terminal.tcc",
            ]),
            processIdentifier: 881,
            timeUnixNano: { 606 }
        )
        let recorder = AgentStudioTCCDiagnosticRecorder(traceRuntime: runtime)

        recorder.recordAppIdentitySnapshot(
            phase: .startupDiagnostic,
            bundleKind: .beta,
            codeIdentityKind: .sameDiskIdentity,
            bundleChanged: false,
            bundleExecutableReachable: true,
            probeSequence: 3,
            rawBundlePath: "/Applications/AgentStudio Beta.app",
            rawExecutablePath: "/Applications/AgentStudio Beta.app/Contents/MacOS/AgentStudio"
        )
        recorder.recordAccessProbe(
            AgentStudioTCCAccessProbeRecord(
                phase: .startupDiagnostic,
                subject: .shellChild,
                target: .messagesData,
                result: .deniedEACCES,
                responsibleKind: .agentStudioBeta,
                commandExitClass: .permissionDenied,
                probeSequence: 3,
                rawProbePath: "/Users/shravansunder/Library/Messages"
            ))
        try await recorder.drain()

        let contents = try String(contentsOf: try #require(runtime.outputFileURL), encoding: .utf8)
        #expect(contents.contains("\"body\":\"terminal.tcc.app_identity_snapshot\""))
        #expect(contents.contains("\"body\":\"terminal.tcc.access_probe\""))
        #expect(contents.contains("\"agentstudio.trace.tag\":\"terminal.tcc\""))
        #expect(contents.contains("\"agentstudio.tcc.phase\":\"startup_diagnostic\""))
        #expect(contents.contains("\"agentstudio.tcc.bundle.kind\":\"beta\""))
        #expect(contents.contains("\"agentstudio.tcc.code_identity.kind\":\"same_disk_identity\""))
        #expect(contents.contains("\"agentstudio.tcc.bundle.changed\":false"))
        #expect(contents.contains("\"agentstudio.tcc.bundle.executable.reachable\":true"))
        #expect(contents.contains("\"agentstudio.tcc.subject\":\"shell_child\""))
        #expect(contents.contains("\"agentstudio.tcc.access.target\":\"messages_data\""))
        #expect(contents.contains("\"agentstudio.tcc.access.result\":\"denied_eacces\""))
        #expect(contents.contains("\"agentstudio.tcc.responsible.kind\":\"agentstudio_beta\""))
        #expect(contents.contains("\"agentstudio.tcc.command.exit_class\":\"permission_denied\""))
        #expect(contents.contains("\"agentstudio.tcc.probe.sequence\":3"))
        #expect(contents.contains("\"agentstudio.tcc.raw.bundle_path\":\"/Applications/AgentStudio Beta.app\""))
        #expect(
            contents.contains(
                "\"agentstudio.tcc.raw.executable_path\":\"/Applications/AgentStudio Beta.app/Contents/MacOS/AgentStudio\""
            ))
        #expect(contents.contains("\"agentstudio.tcc.raw.probe_path\":\"/Users/shravansunder/Library/Messages\""))
    }

    @Test
    func bundleDiskSnapshotClassifiesComparisonResults() {
        let baseline = AgentStudioTCCBundleDiskSnapshot(
            isReachable: true,
            identityToken: "1:2:3:4:5",
            rawBundlePath: "/Applications/AgentStudio.app",
            rawExecutablePath: "/Applications/AgentStudio.app/Contents/MacOS/AgentStudio"
        )
        let same = AgentStudioTCCBundleDiskSnapshot(
            isReachable: true,
            identityToken: "1:2:3:4:5",
            rawBundlePath: baseline.rawBundlePath,
            rawExecutablePath: baseline.rawExecutablePath
        )
        let different = AgentStudioTCCBundleDiskSnapshot(
            isReachable: true,
            identityToken: "1:2:9:4:5",
            rawBundlePath: baseline.rawBundlePath,
            rawExecutablePath: baseline.rawExecutablePath
        )
        let missing = AgentStudioTCCBundleDiskSnapshot(
            isReachable: false,
            identityToken: nil,
            rawBundlePath: baseline.rawBundlePath,
            rawExecutablePath: baseline.rawExecutablePath
        )

        #expect(same.codeIdentityKind(comparedTo: baseline) == .sameDiskIdentity)
        #expect(different.codeIdentityKind(comparedTo: baseline) == .differentDiskIdentity)
        #expect(missing.codeIdentityKind(comparedTo: baseline) == .missing)
    }

    @Test
    func accessProbeResultClassifiesPOSIXErrors() {
        #expect(AgentStudioTCCAccessProbeResult.fromPOSIXErrno(EACCES) == .deniedEACCES)
        #expect(AgentStudioTCCAccessProbeResult.fromPOSIXErrno(EPERM) == .deniedEPERM)
        #expect(AgentStudioTCCAccessProbeResult.fromPOSIXErrno(ENOENT) == .pathMissing)
        #expect(AgentStudioTCCAccessProbeResult.fromPOSIXErrno(EIO) == .unknownError)
    }

    @Test
    func shellChildProbeResultClassifiesPermissionText() {
        #expect(
            AgentStudioTCCDiagnosticRecorder.accessProbeResult(
                exitStatus: 1,
                stderrText: "ls: /Users/example/Documents: Permission denied"
            ) == .deniedEACCES
        )
        #expect(
            AgentStudioTCCDiagnosticRecorder.accessProbeResult(
                exitStatus: 1,
                stderrText: "ls: /Users/example/Documents: Operation not permitted"
            ) == .deniedEPERM
        )
        #expect(
            AgentStudioTCCDiagnosticRecorder.accessProbeResult(
                exitStatus: 1,
                stderrText: "ls: /Users/example/Documents: No such file or directory"
            ) == .pathMissing
        )
    }

    @Test
    func shellChildProbeUsesPinnedBinaryInsteadOfShellStartup() throws {
        let fixtureRoot = FileManager.default.temporaryDirectory
            .appending(path: "agentstudio-tcc-shell-shadow-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
        let zshEnv = fixtureRoot.appending(path: ".zshenv")
        try "ls() { return 0; }\n".write(to: zshEnv, atomically: true, encoding: .utf8)
        setenv("ZDOTDIR", fixtureRoot.path, 1)
        defer { unsetenv("ZDOTDIR") }

        let missingURL = fixtureRoot.appending(path: "missing-directory")
        let outcome = AgentStudioTCCDiagnosticRecorder.shellChildDirectoryProbe(missingURL)

        #expect(outcome.result == .pathMissing)
        #expect(outcome.commandExitClass == .unavailable)
    }

    @Test
    func messagesDataTargetDocumentsFullDiskProbeVocabulary() {
        #expect(AgentStudioTCCAccessTarget.messagesData.rawValue == "messages_data")
    }

    @Test
    func upgradeProbeMonitorConfigurationClampsEnvironmentValues() {
        let configuration = AgentStudioTCCUpgradeProbeMonitorConfiguration.from(environment: [
            "AGENTSTUDIO_TCC_UPGRADE_PROBE_REPEAT_COUNT": "9999",
            "AGENTSTUDIO_TCC_UPGRADE_PROBE_INTERVAL_SECONDS": "-7",
        ])

        #expect(configuration.repeatCount == AgentStudioTCCUpgradeProbeMonitorConfiguration.maximumRepeatCount)
        #expect(configuration.intervalNanoseconds == 1_000_000_000)
    }

    private func temporaryTraceDirectoryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("agentstudio-tcc-diagnostic-recorder-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
