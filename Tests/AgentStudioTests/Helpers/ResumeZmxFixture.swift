import AgentStudioInfrastructure
import Darwin
import Foundation
import Testing

@testable import AgentStudioCore
@testable import AgentStudioTerminal
@testable import AgentStudioTestSupport

struct ResumeZmxFixture: Sendable {
    let harness: ZmxTestHarness
    let basePlan: TerminalColdRestorePlan
    let plan: TerminalColdRestorePlan
    let invocation: ResumeInvocation
    let reportPath: String
    let holdPath: String
    let startupHoldPath: String
    let cliURL: URL
    let callsURL: URL
    let profileURL: URL
    let invocationFolderURL: URL
    let dotDirectory: URL
    private let releases = ForegroundFIFOGroup()
    private let ownership: ResumeEvidenceZmxEnvironment?

    init(
        harness: ZmxTestHarness, providerIdentifier: String, exitCode: Int32,
        providerSessionId: String? = nil, restoreSessionID: ZmxSessionID? = nil,
        reportsToFile: Bool = true, holdResume: Bool = true,
        ownership: ResumeEvidenceZmxEnvironment? = nil
    ) throws {
        self.harness = harness
        self.ownership = ownership
        let sessionDirectory = URL(fileURLWithPath: harness.zmxDir)
        let root = sessionDirectory.appending(path: "resume-proof-\(UUIDv7.generate())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let binDirectory = root.appending(path: "resume bin's directory")
        dotDirectory = root.appending(path: "isolated-zdot")
        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dotDirectory, withIntermediateDirectories: true)
        reportPath = root.appending(path: "resume-argv-fifo").path
        holdPath = root.appending(path: "resume-hold-fifo").path
        startupHoldPath = root.appending(path: "resume-startup-hold-fifo").path
        let fifoPaths = reportsToFile ? [holdPath, startupHoldPath] : [reportPath, holdPath, startupHoldPath]
        for path in fifoPaths {
            guard mkfifo(path, 0o600) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        callsURL = root.appending(path: "resume-calls")
        profileURL = root.appending(path: "login-profile-read")
        invocationFolderURL = root.appending(path: "resume-folder")
        let binaryName = providerIdentifier == "codex" ? "codex" : "claude"
        let cli = binDirectory.appending(path: binaryName)
        cliURL = cli
        let folderReport = reportsToFile ? "pwd >\(quoteResumeFixturePath(invocationFolderURL.path))" : ":"
        let providerMarker = reportsToFile ? "printf '\(ResumeZmxProcessDriver.providerMarker)\\n'" : ":"
        let providerHold =
            holdResume ? "IFS= read -r _agentstudio_resume_release <\(quoteResumeFixturePath(holdPath))" : ":"
        let cliScript = """
            #!/bin/sh
            printf 'called\n' >>\(quoteResumeFixturePath(callsURL.path))
            printf '%s\n%s\n%s\n' "$#" "$1" "$2" >\(quoteResumeFixturePath(reportPath))
            \(folderReport)
            \(providerMarker)
            \(providerHold)
            if [ \(exitCode) -ne 0 ]; then printf 'session-no-longer-exists\n' >&2; fi
            exit \(exitCode)
            """
        try cliScript.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        let profile = """
            export PATH=\(quoteResumeFixturePath(binDirectory.path)):/usr/bin:/bin:/usr/sbin:/sbin
            printf 'login\n' >>\(quoteResumeFixturePath(profileURL.path))
            """
        try profile.write(to: dotDirectory.appending(path: ".zprofile"), atomically: true, encoding: .utf8)
        // zshparam(1) owns this signal: ZSH_EXECUTION_STRING is set exactly
        // for -c. Only the final interactive shell is permitted to print the prompt.
        let shellRC = """
            if [[ -z "$ZSH_EXECUTION_STRING" ]]; then
                PS1='\(ResumeZmxProcessDriver.shellMarker)> '
                RPS1=''
            fi
            """
        try shellRC.write(to: dotDirectory.appending(path: ".zshrc"), atomically: true, encoding: .utf8)
        let provider = try #require(ResumeProvider(providerIdentifier: providerIdentifier))
        let sessionId = try ProviderSessionId(rawValue: providerSessionId ?? UUIDv7.generate().uuidString)
        invocation = ResumeInvocation(provider: provider, sessionId: sessionId)
        let zmxPath = try #require(harness.zmxPath)
        // First attach does not replay pre-client output (zmx handleInit).
        // Read a probe sent through the real attach client's stdin, echo it
        // after Init, then hold the unchanged cold command behind the FIFO.
        let childGateScript = """
            IFS= read -r startup_probe || exit 1
            printf '%s\n' "$startup_probe"
            IFS= read -r _agentstudio_startup_release <"$1"
            shift
            exec "$@"
            """
        let wrapper = root.appending(path: "resume-zmx-startup-gate")
        let wrapperScript = """
            #!/bin/sh
            session_id="$2"
            shift 2
            exec \(quoteResumeFixturePath(zmxPath)) attach "$session_id" /bin/sh -c \(quoteResumeFixturePath(childGateScript)) \
                resume-startup-gate \(quoteResumeFixturePath(startupHoldPath)) "$@"
            """
        try wrapperScript.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        let base = TerminalColdRestorePlan(
            zmxExecutable: wrapper, zmxDirectory: sessionDirectory,
            sessionID: restoreSessionID ?? .generateUUIDv7(), loginShell: URL(fileURLWithPath: "/bin/zsh"),
            folderCandidates: [sessionDirectory],
            notice: .init(linesByCandidateIndex: ["base notice"]), replayFile: nil, resume: nil, attemptID: .generate())
        basePlan = base
        plan = TerminalColdRestorePlanBuilder.applyingResumeEvidence(
            .interruptedCandidate(invocation),
            providerIdentifier: providerIdentifier, providerSessionId: sessionId.rawValue, to: base)
    }

    func launch() async throws -> ResumeZmxProcessDriver {
        try #require(plan.resume == invocation, "the candidate plan must carry its invocation before native launch")
        try #require(!invocation.argv.isEmpty, "resume arguments must exist before waiting for the real CLI")
        return try await launch(plan: plan)
    }

    func launch(plan: TerminalColdRestorePlan) async throws -> ResumeZmxProcessDriver {
        ownership?.retainSession(plan.sessionID)
        print("R3_ZMX_OWNED root=\(harness.zmxDir) session=\(plan.sessionID.rawValue) source=\(#filePath)")
        var environment = ProcessInfo.processInfo.environment
        environment["ZMX_DIR"] = harness.zmxDir
        environment["HOME"] = harness.scratchHomeDirectory
        environment["ZDOTDIR"] = dotDirectory.path
        environment["ZMX_SESSION"] = ""
        environment["ZMX_SESSION_PREFIX"] = ""
        let driver = try await ResumeZmxProcessDriver.launch(
            command: ZmxBackend.buildColdRestoreCommand(plan), environment: environment)
        ownership?.retainClient(driver)
        do {
            try await driver.sendStartupProbe()
            let attached = try await driver.expectStartupGate()
            try #require(attached.contains(ResumeZmxProcessDriver.startupGateMarker))
            try await releaseFIFO(path: startupHoldPath)
            return driver
        } catch {
            try? await killOwnedSession()
            try? await driver.stop()
            throw error
        }
    }

    func receiveArgv() async throws -> [String] {
        try await withoutBlockingCooperativePool {
            let descriptor = open(reportPath, O_RDONLY)
            guard descriptor >= 0 else { throw POSIXError(.EIO) }
            defer { close(descriptor) }
            var result = Data()
            var bytes = [UInt8](repeating: 0, count: 256)
            while true {
                let count = bytes.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
                if count == 0 { break }
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw POSIXError(.EIO) }
                result.append(contentsOf: bytes.prefix(count))
            }
            guard let text = String(data: result, encoding: .utf8) else { throw POSIXError(.EILSEQ) }
            return text.split(separator: "\n").map(String.init)
        }
    }

    func releaseResume() async throws { try await releaseFIFO(path: holdPath) }

    private func releaseFIFO(path: String) async throws {
        let handle = ForegroundFIFOHandle(try await openForegroundFIFO(path: path))
        releases.add(handle)
        try await writeForegroundFIFO(descriptor: handle.descriptor(), bytes: Data([10]))
    }

    func killOwnedSession() async throws {
        defer { releases.closeAll() }
        if let ownership {
            try await ownership.killSession(plan.sessionID)
            return
        }
        let zmxPath = try #require(harness.zmxPath)
        var environment = ProcessInfo.processInfo.environment
        environment["ZMX_DIR"] = harness.zmxDir
        let result = try await runProcessToExit(
            executableURL: URL(fileURLWithPath: zmxPath),
            arguments: ["kill", plan.sessionID.rawValue], environment: environment)
        #expect(result.terminationStatus == 0)
    }
}

private func quoteResumeFixturePath(_ path: String) -> String {
    "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
