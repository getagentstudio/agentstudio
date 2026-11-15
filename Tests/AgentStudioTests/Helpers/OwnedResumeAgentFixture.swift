import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioTestHarness
import Darwin
import Foundation
import Testing

/// An owned real job with a shell-published PID; it never searches a foreground group.
struct OwnedResumeAgentFixture: Sendable {
    let ownership: ResumeEvidenceZmxEnvironment
    let sessionId: ZmxSessionID
    let client: ResumeZmxProcessDriver
    let agent: ZmxProcessIncarnation
    let inputWriter: ForegroundFIFOHandle
    let outputReader: ForegroundFIFOHandle
    let shellReader: ForegroundFIFOHandle
    let controlPath: String?
    let handles: ForegroundFIFOGroup

    static func make(
        ownership: ResumeEvidenceZmxEnvironment, sessionId: ZmxSessionID, provider: String,
        controlledJobStop: Bool
    ) async throws -> Self {
        let endpoints = try OwnedResumeAgentCommand.prepare(
            root: URL(fileURLWithPath: ownership.harness.zmxDir), sessionId: sessionId,
            provider: provider, controlledJobStop: controlledJobStop)
        let shellReader = ForegroundFIFOHandle(try await openForegroundFIFO(path: endpoints.shellPath))
        let client = try await ownership.launchSession(
            sessionId, arguments: ["/bin/sh", "-i", "-c", endpoints.shellCommand])
        try await client.sendStartupProbe()
        _ = try await client.expectStartupGate()
        let input = ForegroundFIFOHandle(try await openForegroundFIFO(path: endpoints.inputPath))
        let output = ForegroundFIFOHandle(try await openForegroundFIFO(path: endpoints.outputPath))
        do {
            let pidBytes = try await readForegroundBytes(
                descriptor: shellReader.descriptor(), byteCount: 10, owner: client)
            let pidText = try #require(String(data: pidBytes, encoding: .utf8))
            let pid = try #require(Int32(pidText))
            let marker = Data("agent-ready".utf8)
            try await writeForegroundFIFO(descriptor: input.descriptor(), bytes: marker)
            #expect(
                try await readForegroundBytes(descriptor: output.descriptor(), byteCount: marker.count, owner: client)
                    == marker)
            let observedAgent = await valueFromDedicatedThread {
                DarwinProcessChainFactsReader().bsdInfo(of: pid)?.incarnation
            }
            let agent = try #require(observedAgent)
            try #require(DarwinColdStartObserverSyscalls().leaderState(of: agent) == .sameIncarnationAlive)
            ownership.retainJobControlChild(agent)
            return Self(
                ownership: ownership, sessionId: sessionId, client: client, agent: agent,
                inputWriter: input, outputReader: output, shellReader: shellReader,
                controlPath: endpoints.controlPath, handles: ForegroundFIFOGroup())
        } catch {
            input.closeOnce()
            output.closeOnce()
            shellReader.closeOnce()
            throw error
        }
    }

    func letAgentExitIntoShell() async throws {
        inputWriter.closeOnce()
        try await expectShellReply("shell-ready")
    }

    func suspendAgentIntoShell(background: Bool) async throws {
        let controlPath = try #require(controlPath)
        try #require(DarwinColdStartObserverSyscalls().leaderState(of: agent) == .sameIncarnationAlive)
        try #require(Darwin.kill(agent.pid, SIGSTOP) == 0)
        try await expectShellReply("agent-stopped")
        if background {
            let command = ForegroundFIFOHandle(try await openForegroundFIFO(path: controlPath))
            handles.add(command)
            try await writeForegroundFIFO(descriptor: command.descriptor(), bytes: Data("background\n".utf8))
            try await expectShellReply("agent-background")
            let marker = Data("background-ready".utf8)
            try await writeForegroundFIFO(descriptor: inputWriter.descriptor(), bytes: marker)
            #expect(
                try await readForegroundBytes(
                    descriptor: outputReader.descriptor(), byteCount: marker.count, owner: client) == marker)
        }
    }

    private func expectShellReply(_ reply: String) async throws {
        let expected = Data(reply.utf8)
        let observed = try await readForegroundBytes(
            descriptor: shellReader.descriptor(), byteCount: expected.count, owner: client)
        try #require(observed == expected, "owned shell did not acknowledge \(reply)")
    }

    func closeHandles() {
        inputWriter.closeOnce()
        outputReader.closeOnce()
        shellReader.closeOnce()
        handles.closeAll()
    }
}

private struct OwnedResumeAgentCommand {
    let inputPath: String
    let outputPath: String
    let shellPath: String
    let controlPath: String?
    let shellCommand: String

    static func prepare(
        root: URL, sessionId: ZmxSessionID, provider: String,
        controlledJobStop: Bool
    ) throws -> Self {
        let binary = root.appending(path: provider)
        let inputPath = root.appending(path: "agent-input-\(sessionId.rawValue)").path
        let outputPath = root.appending(path: "agent-output-\(sessionId.rawValue)").path
        let shellPath = root.appending(path: "shell-ready-\(sessionId.rawValue)").path
        let controlPath = controlledJobStop ? root.appending(path: "job-control-\(sessionId.rawValue)").path : nil
        // Invoke the provider-named symlink while keeping the signed binary in place.
        if !FileManager.default.fileExists(atPath: binary.path) {
            try FileManager.default.createSymbolicLink(atPath: binary.path, withDestinationPath: "/bin/cat")
        }
        for path in [inputPath, outputPath, shellPath] {
            guard mkfifo(path, 0o600) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        if let path = controlPath {
            guard mkfifo(path, 0o600) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        let successor: String
        if let controlPath {
            successor = stoppedAgentShellProtocol(replyPath: shellPath, commandPath: controlPath)
        } else {
            successor = "printf shell-ready >\(quoteForegroundPath(shellPath)); exec /bin/sh -i"
        }
        // An unexpected producer exit must also end a pending startup echo.
        let agentCompletion = controlledJobStop ? "" : "printf '\\000' >\(quoteForegroundPath(outputPath)); "
        let command =
            "IFS= read -r startup; printf '%s\\n' \"$startup\"; set -m; /bin/sh -c 'kill -STOP $$; exec \"$1\"' agent-fixture \(quoteForegroundPath(binary.path)) <\(quoteForegroundPath(inputPath)) >\(quoteForegroundPath(outputPath)) & agent_pid=$!; wait \"$agent_pid\"; printf '%010d' \"$agent_pid\" >\(quoteForegroundPath(shellPath)); fg %+; \(agentCompletion)\(successor)"
        return Self(
            inputPath: inputPath, outputPath: outputPath, shellPath: shellPath, controlPath: controlPath,
            shellCommand: command)
    }
}

private func quoteForegroundPath(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// /bin/sh is Bash 3.2: wait uses WUNTRACED and returns 128 + WSTOPSIG.
/// Keep this parent shell: exec calls end_job_control and terminates stopped jobs.
private func stoppedAgentShellProtocol(replyPath: String, commandPath: String) -> String {
    """
    wait %+; stopped_status=$?
    if [ "$stopped_status" -ne \(128 + SIGSTOP) ]; then
        printf 'job-stop-failed:%s' "$stopped_status" >\(quoteForegroundPath(replyPath)); exit 1
    fi
    printf agent-stopped >\(quoteForegroundPath(replyPath))
    IFS= read -r job_command <\(quoteForegroundPath(commandPath)) || exit 1
    if [ "$job_command" != background ]; then exit 1; fi
    if ! bg %+; then
        printf job-background-failed >\(quoteForegroundPath(replyPath)); exit 1
    fi
    printf agent-background >\(quoteForegroundPath(replyPath))
    IFS= read -r job_retirement <\(quoteForegroundPath(commandPath))
    """
}
