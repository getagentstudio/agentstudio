import AgentStudioInfrastructure
import AgentStudioTestHarness
import AgentStudioTestSupport
import Darwin
import Foundation
import Testing

struct SwiftBuildSlotFixture: Sendable {
    let rootURL: URL
    let fakeExecutableDirectory: URL
    let openFilesMarkerURL: URL
    private let processRegistry = SwiftBuildSlotProcessRegistry()
    private let inheritedEnvironment: [String: String]?

    init(inheritedEnvironment: [String: String]? = nil) throws {
        self.inheritedEnvironment = inheritedEnvironment
        rootURL = FileManager.default.temporaryDirectory
            .appending(path: "swift-build-slot-\(UUIDv7.generate().uuidString)")
        fakeExecutableDirectory = rootURL.appending(path: "fake-bin")
        openFilesMarkerURL = rootURL.appending(path: "open-files")
        let scriptsDirectory = rootURL.appending(path: "scripts")
        try FileManager.default.createDirectory(at: fakeExecutableDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scriptsDirectory, withIntermediateDirectories: true)

        let projectRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        try FileManager.default.copyItem(
            at: projectRoot.appending(path: "scripts/swift-build-slot.sh"),
            to: scriptsDirectory.appending(path: "swift-build-slot.sh")
        )
        try writeExecutable("ps", contents: Self.fakePS)
        try writeExecutable("lsof", contents: Self.fakeLSOF)
        try writeExecutable("sleep", contents: Self.fakeSleep)
    }

    func run(_ script: String, environment: [String: String] = [:]) async throws -> SwiftBuildSlotResult {
        try await withOwnedProcesses { fixture in
            let process = fixture.makeProcess(script, environment: environment)
            process.start()
            let output = try await process.readOutputToEnd()
            return SwiftBuildSlotResult(exitCode: try await process.waitForExit(), output: output)
        }
    }

    func withOwnedProcesses<T: Sendable>(
        _ operation: @escaping @Sendable (Self) async throws -> T
    ) async throws -> T {
        try await withTaskCancellationHandler {
            do {
                let result = try await operation(self)
                try Task.checkCancellation()
                await finishOwnedProcesses()
                return result
            } catch {
                await finishOwnedProcesses()
                throw error
            }
        } onCancel: {
            self.terminateOwnedProcesses()
        }
    }

    var hasRunningHelpers: Bool {
        processRegistry.processes.contains(where: \.isRunning)
    }

    var ownedProcessIdentifiers: [Int32] {
        processRegistry.processes.map(\.processIdentifier)
    }

    func makeProcess(_ script: String, environment overrides: [String: String] = [:]) -> SwiftBuildSlotChildProcess {
        var environment = testProcessEnvironmentWithoutLaneState(inheritedEnvironment)
        let existingPath = environment["PATH"] ?? "/usr/bin:/bin"
        environment["PATH"] = "\(fakeExecutableDirectory.path):\(existingPath)"
        environment["SWIFT_BUILD_SLOT_FAKE_START"] = "Mon Sep 1 00:00:00 2025"
        environment["SWIFT_BUILD_SLOT_PS_REUSED_START"] = "Tue Sep 2 00:00:00 2025"
        environment["SWIFT_BUILD_SLOT_OPEN_FILES_MARKER"] = openFilesMarkerURL.path
        environment["SWIFT_BUILD_SLOT_FAKE_LSOF_PID"] = "4242"
        environment.merge(overrides, uniquingKeysWith: { _, newValue in newValue })

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script]
        process.currentDirectoryURL = rootURL
        process.environment = environment
        let child = SwiftBuildSlotChildProcess(process: process)
        processRegistry.append(child)
        return child
    }

    private func terminateOwnedProcesses() {
        for process in processRegistry.processes {
            process.closeStandardInput()
            process.terminate()
        }
    }

    private func finishOwnedProcesses() async {
        let processes = processRegistry.processes
        for process in processes {
            process.closeStandardInput()
            process.terminate()
        }
        for process in processes {
            _ = try? await process.waitForExit()
        }
        for process in processes {
            _ = await process.drainOutputAfterExit()
        }
        #expect(
            processes.allSatisfy {
                $0.currentDirectoryURL?.standardizedFileURL == rootURL.standardizedFileURL
            },
            "every registered Swift build-slot helper must run from its fixture root"
        )
        #expect(
            processes.allSatisfy { !$0.isRunning },
            "no registered Swift build-slot helper rooted at \(rootURL.path) may remain after fixture cleanup"
        )
    }

    func createFIFO(at url: URL) throws {
        let status = mkfifo(url.path, mode_t(S_IRUSR | S_IWUSR))
        guard status == 0 else {
            throw SwiftBuildSlotScriptError.fifoCreationFailed(url.path, errno)
        }
    }

    func createClaim(slotDirectory: String, processID: String, startTime: String, task: String) throws {
        let claimDirectory = rootURL.appending(path: "\(slotDirectory)/.slot-claim")
        try FileManager.default.createDirectory(at: claimDirectory, withIntermediateDirectories: true)
        let holder = "\(processID)\t\(startTime)\t\(task)\n"
        try Data(holder.utf8).write(to: claimDirectory.appending(path: "holder"))
    }

    func installFailingMove() throws {
        try writeExecutable("mv", contents: "#!/bin/sh\nexit 73\n")
    }

    private func writeExecutable(_ name: String, contents: String) throws {
        let executableURL = fakeExecutableDirectory.appending(path: name)
        try Data(contents.utf8).write(to: executableURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )
    }

    private static let fakePS = """
        #!/bin/sh
        process_id=""
        output_format=""
        while [ "$#" -gt 0 ]; do
          case "$1" in
            -p) process_id="$2"; shift 2 ;;
            -o) output_format="$2"; shift 2 ;;
            *) shift ;;
          esac
        done
        case "$output_format" in
          lstart=)
            if [ "$process_id" = "${SWIFT_BUILD_SLOT_PS_REUSED_PID:-}" ]; then
              printf '%s\\n' "${SWIFT_BUILD_SLOT_PS_REUSED_START:-}"
            else
              printf '%s\\n' "${SWIFT_BUILD_SLOT_FAKE_START:-}"
            fi
            ;;
          command=) printf '%s\\n' 'fixture shell command' ;;
        esac
        """

    private static let fakeLSOF = """
        #!/bin/sh
        target=""
        pid_output=0
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "-t" ]; then pid_output=1; fi
          target="$1"
          shift
        done
        marker="${SWIFT_BUILD_SLOT_OPEN_FILES_MARKER:-}"
        if [ -n "$marker" ] && [ -e "$marker/all" -o -e "$marker/$(basename "$target")" ]; then
          if [ "$pid_output" -eq 1 ]; then printf '%s\\n' "${SWIFT_BUILD_SLOT_FAKE_LSOF_PID:-4242}"; fi
          exit 0
        fi
        exit 1
        """

    private static let fakeSleep = """
        #!/bin/sh
        if [ -n "${SWIFT_BUILD_SLOT_SLEEP_GATE:-}" ]; then
          if ! IFS= read -r _; then
            kill -TERM "$PPID" 2>/dev/null || true
            exit 0
          fi
        else
          /bin/sleep "$@"
        fi
        """
}

final class SwiftBuildSlotChildProcess: @unchecked Sendable {
    let process: Process
    let standardInput: FileHandle
    let standardOutput: Pipe

    private let standardInputPipe: Pipe
    private let processLock = NSLock()
    private var exitTask: Task<Int32, any Error>?
    private var standardInputClosed = false

    init(process: Process) {
        self.process = process
        standardInputPipe = Pipe()
        standardInput = standardInputPipe.fileHandleForWriting
        standardOutput = Pipe()
        process.standardInput = standardInputPipe.fileHandleForReading
        process.standardOutput = standardOutput
        process.standardError = standardOutput
    }

    var processIdentifier: Int32 { process.processIdentifier }
    var isRunning: Bool { process.isRunning }
    var currentDirectoryURL: URL? { process.currentDirectoryURL }

    func start() {
        processLock.lock()
        defer { processLock.unlock() }
        precondition(exitTask == nil, "a Swift build-slot helper may start only once")
        let process = self.process
        exitTask = Task { try await awaitProcessExit(process) }
    }

    func writeStandardInput(_ data: Data) throws {
        try standardInput.write(contentsOf: data)
    }

    func closeStandardInput() {
        let shouldClose = processLock.withLock {
            guard !standardInputClosed else { return false }
            standardInputClosed = true
            return true
        }
        if shouldClose {
            try? standardInput.close()
        }
    }

    func terminate() {
        if process.isRunning {
            process.terminate()
        }
        let exitTask = processLock.withLock { self.exitTask }
        exitTask?.cancel()
    }

    func waitForExit() async throws -> Int32 {
        guard let exitTask = processLock.withLock({ self.exitTask }) else {
            return process.terminationStatus
        }
        return try await exitTask.value
    }

    func readOutput(until marker: String) async throws -> String {
        try await valueFromDedicatedThread {
            var output = ""
            try AgentStudioTests.readOutput(self.standardOutput.fileHandleForReading, into: &output, until: marker)
            return output
        }
    }

    func readOutputToEnd() async throws -> String {
        try await valueFromDedicatedThread {
            try AgentStudioTests.readOutputToEnd(self.standardOutput.fileHandleForReading)
        }
    }

    func drainOutputAfterExit() async -> String {
        guard processLock.withLock({ exitTask != nil }) else { return "" }
        try? standardOutput.fileHandleForWriting.close()
        return
            (try? await withoutBlockingCooperativePool {
                try AgentStudioTests.readOutputToEnd(self.standardOutput.fileHandleForReading)
            }) ?? ""
    }
}

private final class SwiftBuildSlotProcessRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var storedProcesses: [SwiftBuildSlotChildProcess] = []

    var processes: [SwiftBuildSlotChildProcess] {
        lock.withLock { storedProcesses }
    }

    func append(_ process: SwiftBuildSlotChildProcess) {
        lock.withLock {
            storedProcesses.append(process)
        }
    }
}

struct SwiftBuildSlotResult: Sendable {
    let exitCode: Int32
    let output: String
}

enum SwiftBuildSlotScriptError: LocalizedError {
    case missingProcessOutput(String)
    case missingDescendantPID(String)
    case fifoCreationFailed(String, Int32)
    case invalidUTF8Output
    case missingFunction(String)
    case missingTask(String)

    var errorDescription: String? {
        switch self {
        case .missingProcessOutput(let marker):
            "standard output closed before awaited marker '\(marker)'"
        case .missingDescendantPID(let output):
            "descendant PID was missing from process output: \(output)"
        case .fifoCreationFailed(let path, let errorCode):
            "could not create FIFO at \(path): errno \(errorCode)"
        case .invalidUTF8Output:
            "process output was not valid UTF-8"
        case .missingFunction(let functionName):
            "shell function '\(functionName)' was missing"
        case .missingTask(let taskName):
            "mise task '\(taskName)' was missing"
        }
    }
}

func readOutput(_ fileHandle: FileHandle, into output: inout String, until marker: String) throws {
    while !output.contains(marker) {
        let data = fileHandle.availableData
        guard !data.isEmpty else {
            throw SwiftBuildSlotScriptError.missingProcessOutput(marker)
        }
        guard let chunk = String(data: data, encoding: .utf8) else {
            throw SwiftBuildSlotScriptError.invalidUTF8Output
        }
        output += chunk
    }
}

func readOutputToEnd(_ fileHandle: FileHandle) throws -> String {
    let data = try fileHandle.readToEnd() ?? Data()
    guard let output = String(data: data, encoding: .utf8) else {
        throw SwiftBuildSlotScriptError.invalidUTF8Output
    }
    return output
}

func writeLine(_ line: String, to fifoURL: URL) throws {
    let fileHandle = try FileHandle(forWritingTo: fifoURL)
    fileHandle.write(Data(line.utf8))
    try fileHandle.close()
}

func writeLine(_ line: String, to fileHandle: FileHandle) throws {
    try fileHandle.write(contentsOf: Data(line.utf8))
}

func swiftBuildSlotShellFunction(named functionName: String, in source: String) throws -> String {
    let marker = "\(functionName)() {"
    guard let start = source.range(of: marker) else {
        throw SwiftBuildSlotScriptError.missingFunction(functionName)
    }
    let tail = source[start.lowerBound...]
    guard let end = tail.range(of: "\n}") else {
        throw SwiftBuildSlotScriptError.missingFunction(functionName)
    }
    return String(tail[..<end.upperBound])
}

func miseTaskBody(named taskName: String, in config: String) throws -> String {
    let marker = "[tasks.\(taskName)]"
    guard let start = config.range(of: marker) else {
        throw SwiftBuildSlotScriptError.missingTask(taskName)
    }
    let tail = config[start.lowerBound...]
    let blockEnd = tail.range(of: "\n[tasks.")?.lowerBound ?? tail.endIndex
    let block = tail[..<blockEnd]
    guard let bodyStart = block.range(of: "run = \"\"\"\n") else {
        throw SwiftBuildSlotScriptError.missingTask(taskName)
    }
    let script = block[bodyStart.upperBound...]
    guard let bodyEnd = script.range(of: "\n\"\"\"")?.lowerBound else {
        throw SwiftBuildSlotScriptError.missingTask(taskName)
    }
    return String(script[..<bodyEnd])
}
