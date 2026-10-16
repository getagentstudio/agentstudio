import Darwin
import Dispatch
import Foundation

package enum AgentStudioTCCDiagnosticPhase: String, Sendable {
    case startupDiagnostic = "startup_diagnostic"
}

package enum AgentStudioTCCBundleKind: String, Sendable {
    case stable
    case beta
    case debug
    case unknown
}

package enum AgentStudioTCCCodeIdentityKind: String, Sendable {
    case sameDiskIdentity = "same_disk_identity"
    case differentDiskIdentity = "different_disk_identity"
    case missing
    case unknown
}

package enum AgentStudioTCCSubject: String, Sendable {
    case appProcess = "app_process"
    case zmxProcess = "zmx_process"
    case shellChild = "shell_child"
}

package enum AgentStudioTCCAccessTarget: String, Sendable {
    case messagesData = "messages_data"
    case selectedWorkspace = "selected_workspace"
}

package enum AgentStudioTCCAccessProbeResult: String, Sendable {
    case granted
    case deniedEACCES = "denied_eacces"
    case deniedEPERM = "denied_eperm"
    case pathMissing = "path_missing"
    case timedOut = "timed_out"
    case unknownError = "unknown_error"

    static func fromPOSIXErrno(_ errnoValue: Int32) -> Self {
        switch errnoValue {
        case EACCES:
            .deniedEACCES
        case EPERM:
            .deniedEPERM
        case ENOENT:
            .pathMissing
        default:
            .unknownError
        }
    }
}

package enum AgentStudioTCCResponsibleKind: String, Sendable {
    case agentStudioApp = "agentstudio_app"
    case agentStudioBeta = "agentstudio_beta"
    case agentStudioDebug = "agentstudio_debug"
    case shell
    case unknown
}

package enum AgentStudioTCCCommandExitClass: String, Sendable {
    case ok
    case permissionDenied = "permission_denied"
    case timedOut = "timed_out"
    case unavailable
    case unknownError = "unknown_error"
}

package struct AgentStudioTCCAccessProbeOutcome: Equatable, Sendable {
    package let result: AgentStudioTCCAccessProbeResult
    package let commandExitClass: AgentStudioTCCCommandExitClass
    package let rawPath: String
}

package struct AgentStudioTCCAccessProbeRecord: Equatable, Sendable {
    let phase: AgentStudioTCCDiagnosticPhase
    let subject: AgentStudioTCCSubject
    let target: AgentStudioTCCAccessTarget
    let result: AgentStudioTCCAccessProbeResult
    let responsibleKind: AgentStudioTCCResponsibleKind
    let commandExitClass: AgentStudioTCCCommandExitClass
    let startupDiagnosticAction: String?
    let probeSequence: Int?
    let rawProbePath: String?

    package init(
        phase: AgentStudioTCCDiagnosticPhase,
        subject: AgentStudioTCCSubject,
        target: AgentStudioTCCAccessTarget,
        result: AgentStudioTCCAccessProbeResult,
        responsibleKind: AgentStudioTCCResponsibleKind,
        commandExitClass: AgentStudioTCCCommandExitClass,
        startupDiagnosticAction: String? = nil,
        probeSequence: Int? = nil,
        rawProbePath: String?
    ) {
        self.phase = phase
        self.subject = subject
        self.target = target
        self.result = result
        self.responsibleKind = responsibleKind
        self.commandExitClass = commandExitClass
        self.startupDiagnosticAction = startupDiagnosticAction
        self.probeSequence = probeSequence
        self.rawProbePath = rawProbePath
    }
}

package struct AgentStudioTCCBundleDiskSnapshot: Equatable, Sendable {
    package let isReachable: Bool
    let identityToken: String?
    package let rawBundlePath: String?
    package let rawExecutablePath: String?

    package static func current(bundle: Bundle = .main) -> Self {
        let bundlePath = bundle.bundleURL.path
        guard let executableURL = bundle.executableURL else {
            return Self(
                isReachable: false,
                identityToken: nil,
                rawBundlePath: bundlePath,
                rawExecutablePath: nil
            )
        }

        var fileStatus = stat()
        guard stat(executableURL.path, &fileStatus) == 0 else {
            return Self(
                isReachable: false,
                identityToken: nil,
                rawBundlePath: bundlePath,
                rawExecutablePath: executableURL.path
            )
        }

        return Self(
            isReachable: true,
            identityToken: [
                String(fileStatus.st_dev),
                String(fileStatus.st_ino),
                String(fileStatus.st_size),
                String(fileStatus.st_mtimespec.tv_sec),
                String(fileStatus.st_mtimespec.tv_nsec),
            ].joined(separator: ":"),
            rawBundlePath: bundlePath,
            rawExecutablePath: executableURL.path
        )
    }

    package func codeIdentityKind(comparedTo baseline: Self) -> AgentStudioTCCCodeIdentityKind {
        guard isReachable else { return .missing }
        guard let identityToken, let baselineIdentityToken = baseline.identityToken else { return .unknown }
        return identityToken == baselineIdentityToken ? .sameDiskIdentity : .differentDiskIdentity
    }
}

package struct AgentStudioTCCUpgradeProbeMonitorConfiguration: Equatable, Sendable {
    static let repeatCountEnvironmentKey = "AGENTSTUDIO_TCC_UPGRADE_PROBE_REPEAT_COUNT"
    static let intervalSecondsEnvironmentKey = "AGENTSTUDIO_TCC_UPGRADE_PROBE_INTERVAL_SECONDS"
    static let maximumRepeatCount = 720
    static let maximumIntervalSeconds = 3600

    package let repeatCount: Int
    package let intervalNanoseconds: UInt64

    package static func from(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Self {
        let repeatCount = clampedInteger(
            environment[repeatCountEnvironmentKey],
            defaultValue: 0,
            minimum: 0,
            maximum: maximumRepeatCount
        )
        let intervalSeconds = clampedInteger(
            environment[intervalSecondsEnvironmentKey],
            defaultValue: 5,
            minimum: 1,
            maximum: maximumIntervalSeconds
        )
        return Self(
            repeatCount: repeatCount,
            intervalNanoseconds: UInt64(intervalSeconds) * 1_000_000_000
        )
    }

    private static func clampedInteger(
        _ rawValue: String?,
        defaultValue: Int,
        minimum: Int,
        maximum: Int
    ) -> Int {
        guard
            let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
            let parsedValue = Int(rawValue)
        else { return defaultValue }
        return min(max(parsedValue, minimum), maximum)
    }
}

package final class AgentStudioTCCDiagnosticRecorder: @unchecked Sendable {
    private let traceRuntime: AgentStudioTraceRuntime?
    private let eventQueue: AgentStudioTraceEventQueue?

    package init(traceRuntime: AgentStudioTraceRuntime?) {
        self.traceRuntime = traceRuntime
        if let traceRuntime, traceRuntime.isEnabled {
            self.eventQueue = AgentStudioTraceEventQueue(traceRuntime: traceRuntime)
        } else {
            self.eventQueue = nil
        }
    }

    package func recordAppIdentitySnapshot(
        phase: AgentStudioTCCDiagnosticPhase,
        bundleKind: AgentStudioTCCBundleKind,
        codeIdentityKind: AgentStudioTCCCodeIdentityKind,
        bundleChanged: Bool,
        bundleExecutableReachable: Bool,
        startupDiagnosticAction: String? = nil,
        probeSequence: Int? = nil,
        rawBundlePath: String?,
        rawExecutablePath: String? = nil
    ) {
        var attributes: [String: AgentStudioTraceValue] = [
            "agentstudio.tcc.phase": .string(phase.rawValue),
            "agentstudio.tcc.bundle.kind": .string(bundleKind.rawValue),
            "agentstudio.tcc.code_identity.kind": .string(codeIdentityKind.rawValue),
            "agentstudio.tcc.bundle.changed": .bool(bundleChanged),
            "agentstudio.tcc.bundle.executable.reachable": .bool(bundleExecutableReachable),
        ]
        if let startupDiagnosticAction {
            attributes["agentstudio.startup_diagnostic.action"] = .string(startupDiagnosticAction)
        }
        if let probeSequence {
            attributes["agentstudio.tcc.probe.sequence"] = .int(probeSequence)
        }
        if let rawBundlePath {
            attributes["agentstudio.tcc.raw.bundle_path"] = .string(rawBundlePath)
        }
        if let rawExecutablePath {
            attributes["agentstudio.tcc.raw.executable_path"] = .string(rawExecutablePath)
        }
        record(body: "terminal.tcc.app_identity_snapshot", attributes: attributes)
    }

    package func recordAccessProbe(_ accessProbeRecord: AgentStudioTCCAccessProbeRecord) {
        var attributes: [String: AgentStudioTraceValue] = [
            "agentstudio.tcc.phase": .string(accessProbeRecord.phase.rawValue),
            "agentstudio.tcc.subject": .string(accessProbeRecord.subject.rawValue),
            "agentstudio.tcc.access.target": .string(accessProbeRecord.target.rawValue),
            "agentstudio.tcc.access.result": .string(accessProbeRecord.result.rawValue),
            "agentstudio.tcc.responsible.kind": .string(accessProbeRecord.responsibleKind.rawValue),
            "agentstudio.tcc.command.exit_class": .string(accessProbeRecord.commandExitClass.rawValue),
        ]
        if let startupDiagnosticAction = accessProbeRecord.startupDiagnosticAction {
            attributes["agentstudio.startup_diagnostic.action"] = .string(startupDiagnosticAction)
        }
        if let probeSequence = accessProbeRecord.probeSequence {
            attributes["agentstudio.tcc.probe.sequence"] = .int(probeSequence)
        }
        if let rawProbePath = accessProbeRecord.rawProbePath {
            attributes["agentstudio.tcc.raw.probe_path"] = .string(rawProbePath)
        }
        record(body: "terminal.tcc.access_probe", attributes: attributes)
    }

    package func drain() async throws {
        try await eventQueue?.drain()
        if eventQueue == nil {
            try await traceRuntime?.flush()
        }
    }

    package static func shellChildMessagesDataDirectoryProbe() -> AgentStudioTCCAccessProbeOutcome {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Messages", isDirectory: true)
        return shellChildDirectoryProbe(url)
    }

    static func shellChildDirectoryProbe(_ url: URL) -> AgentStudioTCCAccessProbeOutcome {
        let process = Process()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ls")
        process.environment = [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "LANG": "C",
            "LC_ALL": "C",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        ]
        process.arguments = ["-d", url.path]
        process.standardOutput = Pipe()
        process.standardError = standardError
        let completion = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            completion.signal()
        }

        do {
            try process.run()
        } catch {
            return AgentStudioTCCAccessProbeOutcome(
                result: .unknownError,
                commandExitClass: .unknownError,
                rawPath: url.path
            )
        }
        let timeoutResult = completion.wait(timeout: .now() + 2)
        if timeoutResult == .timedOut {
            process.terminate()
            process.waitUntilExit()
            return AgentStudioTCCAccessProbeOutcome(
                result: .timedOut,
                commandExitClass: .timedOut,
                rawPath: url.path
            )
        }

        if process.terminationStatus == 0 {
            return AgentStudioTCCAccessProbeOutcome(
                result: .granted,
                commandExitClass: .ok,
                rawPath: url.path
            )
        }

        let stderrData = standardError.fileHandleForReading.readDataToEndOfFile()
        let stderrText = String(bytes: stderrData, encoding: .utf8) ?? ""
        let result = accessProbeResult(exitStatus: process.terminationStatus, stderrText: stderrText)
        return AgentStudioTCCAccessProbeOutcome(
            result: result,
            commandExitClass: commandExitClass(for: result),
            rawPath: url.path
        )
    }

    package static func bundleKind(
        releaseChannel: AppDataPaths.ReleaseChannel = .current,
        isDebugBuild: Bool = AppDataPaths.isDebugBuild
    ) -> AgentStudioTCCBundleKind {
        if isDebugBuild {
            return .debug
        }
        switch releaseChannel {
        case .stable:
            return .stable
        case .beta:
            return .beta
        }
    }

    package static func responsibleKind(
        for bundleKind: AgentStudioTCCBundleKind
    ) -> AgentStudioTCCResponsibleKind {
        switch bundleKind {
        case .stable:
            .agentStudioApp
        case .beta:
            .agentStudioBeta
        case .debug:
            .agentStudioDebug
        case .unknown:
            .unknown
        }
    }

    static func accessProbeResult(exitStatus: Int32, stderrText: String) -> AgentStudioTCCAccessProbeResult {
        if exitStatus == 0 {
            return .granted
        }
        if stderrText.localizedCaseInsensitiveContains("Permission denied") {
            return .deniedEACCES
        }
        if stderrText.localizedCaseInsensitiveContains("Operation not permitted") {
            return .deniedEPERM
        }
        if stderrText.localizedCaseInsensitiveContains("No such file") {
            return .pathMissing
        }
        return .unknownError
    }

    private static func commandExitClass(
        for result: AgentStudioTCCAccessProbeResult
    ) -> AgentStudioTCCCommandExitClass {
        switch result {
        case .granted:
            .ok
        case .deniedEACCES, .deniedEPERM:
            .permissionDenied
        case .timedOut:
            .timedOut
        case .pathMissing:
            .unavailable
        case .unknownError:
            .unknownError
        }
    }

    private func record(body: String, attributes: [String: AgentStudioTraceValue]) {
        guard let traceRuntime, traceRuntime.isEnabled(.terminalTCC), let eventQueue else { return }
        eventQueue.record(
            tag: .terminalTCC,
            body: body,
            eventTimeUnixNano: traceRuntime.timestampUnixNano(),
            attributes: attributes
        )
    }
}
