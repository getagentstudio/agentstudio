import AgentStudioTestHarness
import Darwin
import Foundation
import Synchronization
import Testing

@testable import AgentStudioInfrastructure

@Suite(.serialized)
final class ProcessExecutorTests {
    private var executor: DefaultProcessExecutor!

    init() {
        executor = DefaultProcessExecutor()
    }

    // MARK: - Basic Execution

    @Test
    func test_execute_capturesStdout() async throws {
        // Act
        let result = try await executor.execute(
            command: "echo",
            args: ["hello"],
            cwd: nil,
            environment: nil
        )

        // Assert
        #expect(result.stdout == "hello")
        #expect(result.succeeded)
    }

    @Test
    func test_execute_capturesExitCode() async throws {
        // Act
        let result = try await executor.execute(
            command: "false",
            args: [],
            cwd: nil,
            environment: nil
        )

        // Assert
        #expect(result.exitCode == 1)
        #expect(!result.succeeded)
    }

    @Test
    func test_execute_respectsCwd() async throws {
        // Act
        let result = try await executor.execute(
            command: "pwd",
            args: [],
            cwd: URL(fileURLWithPath: "/tmp"),
            environment: nil
        )

        // Assert — macOS may resolve /tmp to /private/tmp
        #expect(
            result.stdout.contains("/tmp"),
            "Expected stdout to contain /tmp, got: \(result.stdout)"
        )
    }

    // MARK: - Environment

    @Test
    func test_execute_mergesEnvironmentOverrides() async throws {
        // Arrange
        let customEnv = ["AGENTSTUDIO_TEST_VAR": "test_value_12345"]

        // Act
        let result = try await executor.execute(
            command: "env",
            args: [],
            cwd: nil,
            environment: customEnv
        )

        // Assert
        #expect(
            result.stdout.contains("AGENTSTUDIO_TEST_VAR=test_value_12345"),
            "Expected env to contain custom var"
        )
    }

    @Test
    func test_execute_preservesPathPrefix() async throws {
        // Act
        let result = try await executor.execute(
            command: "env",
            args: [],
            cwd: nil,
            environment: nil
        )

        // Assert — verify homebrew/local paths are prepended
        let pathLine = result.stdout
            .components(separatedBy: "\n")
            .first { $0.hasPrefix("PATH=") }

        #expect(pathLine != nil, "Expected PATH in environment output")
        if let pathLine {
            #expect(
                pathLine.contains("/opt/homebrew/bin") || pathLine.contains("/usr/local/bin"),
                "Expected PATH to include homebrew or local bin paths"
            )
        }
    }

    @Test
    func test_execute_rebuildsPathWhenOverrideIsEmpty() async throws {
        // Act
        let result = try await executor.execute(
            command: "env",
            args: [],
            cwd: nil,
            environment: ["PATH": ""]
        )

        // Assert
        let pathLine = result.stdout
            .components(separatedBy: "\n")
            .first { $0.hasPrefix("PATH=") }

        #expect(pathLine != nil, "Expected PATH in environment output")
        if let pathLine {
            #expect(pathLine.contains("/opt/homebrew/bin"))
            #expect(pathLine.contains("/usr/local/bin"))
            #expect(pathLine.contains("/usr/bin"))
        }
    }

    @Test
    func test_execute_rebuildsHomeWhenOverrideIsEmpty() async throws {
        // Act
        let result = try await executor.execute(
            command: "env",
            args: [],
            cwd: nil,
            environment: ["HOME": ""]
        )

        // Assert
        let homeLine = result.stdout
            .components(separatedBy: "\n")
            .first { $0.hasPrefix("HOME=") }

        #expect(homeLine != nil, "Expected HOME in environment output")
        if let homeLine {
            #expect(homeLine.count > "HOME=".count)
            #expect(homeLine != "HOME=")
        }
    }

    // MARK: - Timeout

    @Test
    func test_execute_timeoutTerminatesHangingProcess() async throws {
        // Arrange
        let clock = TestPushClock()
        let timeoutSeconds: TimeInterval = 1
        let launchStep = HeldStep<Void>("timeout process before launch")
        let controlledExecutor = DefaultProcessExecutor(
            timeout: timeoutSeconds,
            clock: clock,
            beforeLaunch: { try? launchStep.arriveBlocking(()) }
        )
        let task = Task {
            try await controlledExecutor.execute(
                command: "sleep",
                args: ["20"],
                cwd: nil,
                environment: nil
            )
        }
        defer {
            launchStep.release()
            task.cancel()
        }

        // Act — the timeout sleep is registered only after Process.run succeeds.
        _ = try await launchStep.firstArrival()
        launchStep.release()
        await clock.waitForPendingSleepCount(exactly: 1)
        clock.advance(by: .seconds(timeoutSeconds))

        // Assert
        do {
            _ = try await task.value
            Issue.record("Expected ProcessError.timedOut to be thrown")
        } catch let error as ProcessError {
            // Assert
            if case .timedOut(let cmd, let seconds) = error {
                #expect(cmd == "sleep")
                #expect(seconds == timeoutSeconds)
            } else {
                Issue.record("Expected .timedOut, got: \(error)")
            }
        } catch {
            Issue.record("Expected .timedOut, got: \(error)")
        }
        #expect(clock.pendingSleepCount == 0)
    }

    @Test
    func test_execute_normalCommandDoesNotTimeout() async throws {
        // Arrange — time never advances; normal exit cancels the timeout sleep.
        let clock = TestPushClock()
        let controlledExecutor = DefaultProcessExecutor(clock: clock)

        // Act
        let result = try await controlledExecutor.execute(
            command: "echo",
            args: ["fast"],
            cwd: nil,
            environment: nil
        )

        // Assert — should succeed normally, no timeout
        #expect(result.stdout == "fast")
        #expect(result.succeeded)
        #expect(clock.pendingSleepCount == 0)
    }

    @Test
    func test_execute_concurrentTimeoutsDoNotStarve() async throws {
        let clock = TestPushClock()
        let timeoutSeconds: TimeInterval = 1
        let concurrentExecutor = DefaultProcessExecutor(timeout: timeoutSeconds, clock: clock)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    do {
                        _ = try await concurrentExecutor.execute(
                            command: "sleep",
                            args: ["20"],
                            cwd: nil,
                            environment: nil
                        )
                        Issue.record("Expected concurrent sleep command to time out")
                    } catch let error as ProcessError {
                        guard case .timedOut(let command, let seconds) = error else {
                            Issue.record("Expected .timedOut, got: \(error)")
                            return
                        }
                        #expect(command == "sleep")
                        #expect(seconds == timeoutSeconds)
                    } catch {
                        Issue.record("Expected .timedOut, got: \(error)")
                    }
                }
            }

            await clock.waitForPendingSleepCount(exactly: 6)
            clock.advance(by: .seconds(timeoutSeconds))
            await group.waitForAll()
        }

        #expect(clock.pendingSleepCount == 0)
    }

    @Test
    func test_execute_cancellationWinsOverProcessTimeout() async throws {
        // Arrange — cancellation should tear down the child process promptly instead of
        // waiting for the executor's subprocess timeout path to fire.
        let clock = TestPushClock()
        let cancellationExecutor = DefaultProcessExecutor(clock: clock)

        // Act
        let task = Task {
            try await cancellationExecutor.execute(
                command: "sleep",
                args: ["20"],
                cwd: nil,
                environment: nil
            )
        }
        task.cancel()

        // Assert
        do {
            _ = try await task.value
            Issue.record("Expected CancellationError to be thrown")
        } catch is CancellationError {
            // expected
        } catch {
            Issue.record("Expected CancellationError, got: \(error)")
        }
        #expect(clock.pendingSleepCount == 0)
    }

    @Test
    func test_execute_cancellationBeforeLaunchStartsNoChild() async throws {
        // Arrange
        let processIdentifierURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentstudio-process-\(UUIDv7.generate().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: processIdentifierURL) }
        let launchStep = HeldStep<Void>("before-process-launch", cancellation: .holdThroughCancellation)
        let cancellationExecutor = DefaultProcessExecutor(
            timeout: 20,
            beforeLaunch: { try? launchStep.arriveBlocking(()) }
        )
        let task = Task {
            try await cancellationExecutor.execute(
                command: "sh",
                args: [
                    "-c",
                    "printf '%s' \"$$\" > \"$1\"",
                    "agentstudio-process-executor-test",
                    processIdentifierURL.path,
                ],
                cwd: nil,
                environment: nil
            )
        }
        defer { launchStep.release() }
        _ = try await launchStep.firstArrival()

        // Act
        task.cancel()
        launchStep.release()

        // Assert
        do {
            _ = try await task.value
            Issue.record("Expected CancellationError to be thrown")
        } catch is CancellationError {
            // expected
        } catch {
            Issue.record("Expected CancellationError, got: \(error)")
        }
        #expect(!FileManager.default.fileExists(atPath: processIdentifierURL.path))
    }

    @Test
    func test_execute_cancellationReturnsOnlyAfterChildExit() async throws {
        // Arrange
        let fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentstudio-process-\(UUIDv7.generate().uuidString)")
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }
        let processIdentifierFIFO = fixtureDirectory.appendingPathComponent("process-identifier.fifo")
        guard mkfifo(processIdentifierFIFO.path, 0o600) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let readerDescriptor = open(processIdentifierFIFO.path, O_RDONLY | O_NONBLOCK)
        guard readerDescriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let processIdentifierReader = FileHandle(fileDescriptor: readerDescriptor, closeOnDealloc: true)
        defer { try? processIdentifierReader.close() }
        // Keep one writer open so the nonblocking reader does not see EOF before the child starts.
        let writerDescriptor = open(processIdentifierFIFO.path, O_WRONLY | O_NONBLOCK)
        guard writerDescriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let keepaliveWriter = FileHandle(fileDescriptor: writerDescriptor, closeOnDealloc: true)
        defer { try? keepaliveWriter.close() }
        let cancellationExecutor = DefaultProcessExecutor(timeout: 20)
        let task = Task {
            try await cancellationExecutor.execute(
                command: "sh",
                args: [
                    "-c",
                    "printf '%s\\n' \"$$\" > \"$1\"; trap '' TERM; while :; do :; done",
                    "agentstudio-process-executor-test",
                    processIdentifierFIFO.path,
                ],
                cwd: nil,
                environment: nil
            )
        }
        let childProcessIdentifier = try await receiveProcessIdentifier(
            from: processIdentifierReader,
            keepingOpenWith: keepaliveWriter
        )

        // Act
        task.cancel()

        // Assert
        do {
            _ = try await task.value
            Issue.record("Expected CancellationError to be thrown")
        } catch is CancellationError {
            // expected
        } catch {
            Issue.record("Expected CancellationError, got: \(error)")
        }
        errno = 0
        #expect(kill(childProcessIdentifier, 0) == -1)
        #expect(errno == ESRCH)
    }

    // MARK: - Regression: Fast Exit (Group 8)

    @Test
    func test_execute_fastExitDoesNotHang() async throws {
        // Regression test for the Group 8 fix: fast-exiting processes like
        // `true` (~0ms) must complete without hanging. The old code set
        // terminationHandler after pipe reads, missing already-exited processes.

        // Act — `true` exits immediately with code 0
        let result = try await executor.execute(
            command: "true",
            args: [],
            cwd: nil,
            environment: nil
        )

        // Assert
        #expect(result.exitCode == 0)
        #expect(result.succeeded)
    }

    // MARK: - Regression: Pipe Capacity

    @Test
    func test_execute_drainsStderrBeyondKernelPipeCapacity() async throws {
        // A child that writes past the kernel pipe buffer (64 KiB on Darwin) blocks in
        // write() until the parent drains it. Waiting for exit before reading is therefore
        // a deadlock, not a slow test: the parent waits for a child that cannot finish.
        // The executor reads both pipes concurrently with the child's lifetime and only
        // completes once exit and both EOFs have arrived, so capacity never enters into it.
        let byteCount = 200_000

        // Act
        let result = try await executor.execute(
            command: "sh",
            args: ["-c", "yes x | head -c \(byteCount) >&2"],
            cwd: nil,
            environment: nil
        )

        // Assert
        #expect(result.succeeded)
        #expect(result.stderr.count > 65_536)  // past the pipe capacity that deadlocks the old shape
        #expect(result.stderr.count == byteCount - 1)  // decodeAndTrim drops the single trailing newline
    }

    private func receiveProcessIdentifier(
        from reader: FileHandle,
        keepingOpenWith keepaliveWriter: FileHandle
    ) async throws -> pid_t {
        let receiptState = Mutex(ProcessIdentifierReceiptState())
        return try await withCheckedThrowingContinuation { continuation in
            reader.readabilityHandler = { handle in
                let bytes = handle.availableData
                guard !bytes.isEmpty else { return }
                let result = receiptState.withLock { state -> Result<pid_t, ProcessExecutorTestError>? in
                    guard !state.completed else { return nil }
                    state.bytes.append(bytes)
                    guard let newlineIndex = state.bytes.firstIndex(of: 0x0A) else { return nil }
                    state.completed = true
                    guard
                        let identifierText = String(bytes: state.bytes[..<newlineIndex], encoding: .utf8),
                        let processIdentifier = pid_t(identifierText), processIdentifier > 0
                    else {
                        return .failure(.invalidProcessIdentifier)
                    }
                    return .success(processIdentifier)
                }
                guard let result else { return }
                handle.readabilityHandler = nil
                try? handle.close()
                try? keepaliveWriter.close()
                switch result {
                case .success(let processIdentifier):
                    continuation.resume(returning: processIdentifier)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

private enum ProcessExecutorTestError: Error {
    case invalidProcessIdentifier
}

private struct ProcessIdentifierReceiptState: Sendable {
    var bytes = Data()
    var completed = false
}
