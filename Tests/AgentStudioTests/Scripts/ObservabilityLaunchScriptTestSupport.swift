import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioTestHarness
import AgentStudioTestSupport
import Darwin
import Foundation
import Testing

struct LauncherScriptFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "agentstudio-launcher-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func url(_ relativePath: String) -> URL {
        root.appending(path: relativePath)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    func executable(_ name: String, _ contents: String) throws -> URL {
        let executableURL = url(name)
        try contents.write(to: executableURL, atomically: true, encoding: .utf8)
        chmod(executableURL.path, 0o755)
        return executableURL
    }

    static var currentProcessStartIdentity: String {
        var processInfo = proc_bsdinfo()
        let infoSize = Int32(MemoryLayout.size(ofValue: processInfo))
        let result = proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &processInfo, infoSize)
        precondition(result == infoSize)
        return "\(processInfo.pbi_start_tvsec):\(processInfo.pbi_start_tvusec)"
    }

    func makeAppBundle(
        name: String,
        releaseChannel: String,
        bundleIdentifier: String = "com.agentstudio.app.beta",
        debugCode: String? = nil
    ) throws -> URL {
        let appURL = url(name)
        let contentsURL = appURL.appending(path: "Contents")
        let macOSURL = contentsURL.appending(path: "MacOS")
        try FileManager.default.createDirectory(at: macOSURL, withIntermediateDirectories: true)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
          "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>CFBundleIdentifier</key>
          <string>\(bundleIdentifier)</string>
          \(debugCode.map { "<key>AgentStudioDebugCode</key><string>\($0)</string>" } ?? "")
          <key>CFBundleShortVersionString</key>
          <string>0.0.0-test</string>
          <key>AgentStudioReleaseChannel</key>
          <string>\(releaseChannel)</string>
        </dict>
        </plist>
        """.write(to: contentsURL.appending(path: "Info.plist"), atomically: true, encoding: .utf8)
        let binaryURL = macOSURL.appending(path: "AgentStudio")
        try "#!/bin/bash\nexit 0\n".write(to: binaryURL, atomically: true, encoding: .utf8)
        chmod(binaryURL.path, 0o755)
        return appURL
    }

    func makeDebugBuildExecutable(_ contents: String) throws -> URL {
        let buildPath = url("debug-build")
        let debugPath = buildPath.appending(path: "debug")
        try FileManager.default.createDirectory(at: debugPath, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: debugPath.appending(path: "AgentStudio_AgentStudio.bundle"),
            withIntermediateDirectories: true)
        let binaryURL = debugPath.appending(path: "AgentStudio")
        try contents.write(to: binaryURL, atomically: true, encoding: .utf8)
        chmod(binaryURL.path, 0o755)
        try makeDebugBuildCLI(
            """
            #!/bin/bash
            printf '%s\\n' "$@" > '\(url("ipc-health-arguments").path)'
            [ "${!#}" = system.ping ] || exit 64
            exit 0
            """
        )
        return buildPath
    }

    @discardableResult
    func makeDebugBuildCLI(_ contents: String) throws -> URL {
        try executable("debug-build/debug/agentstudio-cli", contents)
    }

    func makeDebugEscrow(name: String = "ipc-escrow.json", socketPath: String? = nil) throws -> URL {
        let escrowURL = url(name)
        let document = IPCDebugCredentialEscrowDocument(
            runtimeId: UUIDv7.generate(),
            socketPath: socketPath ?? url("ipc-socket/agentstudio.sock").path,
            token: "fixture-debug-credential"
        )
        try JSONEncoder().encode(document).write(to: escrowURL)
        chmod(escrowURL.path, 0o600)
        return escrowURL
    }

    func expectIPCHealthChecked() throws {
        let arguments = try String(contentsOf: url("ipc-health-arguments"), encoding: .utf8)
        #expect(arguments.split(separator: "\n").last == "system.ping")
    }

    func runScript(
        _ scriptPath: String,
        arguments: [String],
        environment: [String: String]
    ) async throws -> ScriptRunResult {
        let stackHelper = try executable(
            "observability-stack",
            """
            #!/bin/bash
            if [ "${1:-}" = "collector-url" ]; then
              echo "http://127.0.0.1:4318"
            fi
            exit 0
            """
        )
        let curl = try executable(
            "curl",
            """
            #!/bin/bash
            exit 0
            """
        )
        let launchClock = try executable(
            "default-launch-clock",
            """
            #!/bin/bash
            count=0
            [ ! -f '\(url("launch-clock-count").path)' ] || count=$(cat '\(url("launch-clock-count").path)')
            count=$((count + 1))
            printf '%s' "$count" > '\(url("launch-clock-count").path)'
            awk -v count="$count" -v attempts="${AGENTSTUDIO_PID_WAIT_ATTEMPTS:-200}" 'BEGIN { print count * attempts * 0.1 / 16 }'
            """
        )
        let processAlive = try executable("default-process-alive", "#!/bin/bash\nexit 0\n")
        var mergedEnvironment = testProcessEnvironmentWithoutLaneState()
        mergedEnvironment["HOME"] = root.path
        mergedEnvironment["AGENTSTUDIO_OBSERVABILITY_ALLOW_TEST_OVERRIDES"] = "1"
        mergedEnvironment["AI_TOOLS_OBSERVABILITY_STACK_HELPER"] = stackHelper.path
        mergedEnvironment["AI_TOOLS_OBSERVABILITY_COLLECTOR_HEALTH_URL"] = "http://127.0.0.1:13133/"
        mergedEnvironment["AGENTSTUDIO_CURL_BIN"] = curl.path
        mergedEnvironment["AGENTSTUDIO_DEBUG_ARTIFACT_DIR"] = url("debug-app-artifacts").path
        mergedEnvironment["AGENTSTUDIO_DEBUG_BUILD_PATH"] = url("debug-build").path
        if URL(fileURLWithPath: scriptPath).lastPathComponent == "run-debug-observability.sh" {
            mergedEnvironment["AGENTSTUDIO_IPC_SOCKET_DIR"] = url("ipc-socket").path
        }
        mergedEnvironment["AGENTSTUDIO_OBSERVABILITY_TEST_LAUNCH_CLOCK_BIN"] = launchClock.path
        mergedEnvironment["AGENTSTUDIO_OBSERVABILITY_TEST_PROCESS_ALIVE_BIN"] = processAlive.path
        for (key, value) in environment {
            mergedEnvironment[key] = value
        }
        return try await run(
            executableURL: URL(fileURLWithPath: "/bin/bash"),
            arguments: [scriptPath] + arguments,
            currentDirectoryURL: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
            environment: mergedEnvironment
        )
    }

    func runVerifier(
        scriptPath: String = "scripts/verify-beta-observability.sh",
        stateFile: URL,
        environment: [String: String]
    ) async throws -> ScriptRunResult {
        var mergedEnvironment = testProcessEnvironmentWithoutLaneState()
        mergedEnvironment["AGENTSTUDIO_OBSERVABILITY_STATE_FILE"] = stateFile.path
        for (key, value) in environment {
            mergedEnvironment[key] = value
        }
        return try await run(
            executableURL: URL(fileURLWithPath: "/bin/bash"),
            arguments: [scriptPath],
            currentDirectoryURL: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
            environment: mergedEnvironment
        )
    }

    func worktreeDebugCode(for rootPath: String = FileManager.default.currentDirectoryPath) async throws -> String {
        let output = try await run(
            executableURL: try await TestToolResolver.resolved().python3,
            arguments: [
                "-c",
                """
                import hashlib, os, sys
                alphabet = "0123456789abcdefghijklmnopqrstuvwxyz"
                space = 36 ** 4
                root = os.path.realpath(sys.argv[1])
                value = int.from_bytes(hashlib.sha256(root.encode("utf-8")).digest()[:4], "big") % space
                chars = []
                for _ in range(4):
                    value, digit = divmod(value, 36)
                    chars.append(alphabet[digit])
                print("".join(reversed(chars)))
                """,
                rootPath,
            ],
            currentDirectoryURL: nil,
            environment: nil
        )
        return output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Waits until `url` exists and contains `expectedContent`, with no deadline, and returns
    /// the contents that satisfied the wait.
    ///
    /// The detached child writes the file whenever it gets scheduled, so the wait
    /// completes on the filesystem event that makes the condition true; the lane's
    /// hang bound is the only elapsed-time bound on it. Each turn arms a watch on
    /// the file, or on its directory while the file does not exist yet, before it
    /// checks the condition, so a write between the check and the wait still wakes it.
    func waitForFile(_ url: URL, containing expectedContent: String) async throws -> String {
        try await withoutBlockingCooperativePool {
            while true {
                let watchedURL =
                    FileManager.default.fileExists(atPath: url.path) ? url : url.deletingLastPathComponent()
                let fileDescriptor = open(watchedURL.path, O_EVTONLY)
                guard fileDescriptor >= 0 else {
                    throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: watchedURL.path])
                }
                let changeSignal = DispatchSemaphore(value: 0)
                let cancelSignal = DispatchSemaphore(value: 0)
                let source = DispatchSource.makeFileSystemObjectSource(
                    fileDescriptor: fileDescriptor,
                    eventMask: [.write, .extend, .attrib, .rename, .delete],
                    queue: DispatchQueue.global(qos: .userInitiated)
                )
                source.setEventHandler {
                    changeSignal.signal()
                }
                source.setCancelHandler {
                    close(fileDescriptor)
                    cancelSignal.signal()
                }
                source.resume()

                let contents = try? String(contentsOf: url, encoding: .utf8)
                let satisfyingContents = contents.flatMap { $0.contains(expectedContent) ? $0 : nil }
                if satisfyingContents == nil {
                    changeSignal.wait()
                }
                source.cancel()
                cancelSignal.wait()
                if let satisfyingContents {
                    return satisfyingContents
                }
            }
        }
    }

    private func run(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL?,
        environment: [String: String]?
    ) async throws -> ScriptRunResult {
        let output = try await runProcessToExit(
            executableURL: executableURL,
            arguments: arguments,
            currentDirectoryURL: currentDirectoryURL,
            environment: environment
        )
        return ScriptRunResult(
            exitCode: output.terminationStatus,
            stdout: String(data: output.standardOutput, encoding: .utf8) ?? "",
            stderr: String(data: output.standardError, encoding: .utf8) ?? ""
        )
    }
}

func shellEscapedStateValue(_ value: String) -> String {
    value.replacingOccurrences(of: " ", with: "\\ ")
}

struct ScriptRunResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}
