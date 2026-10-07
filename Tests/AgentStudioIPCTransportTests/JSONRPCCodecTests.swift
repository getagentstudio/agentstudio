import AgentStudioIPCTransport
import AgentStudioTestHarness
import Foundation
import Testing

@Suite("JSON-RPC codec")
struct JSONRPCCodecTests {
    @Test("decodes a strict JSON-RPC 2 request with object params")
    func decodesStrictRequestWithObjectParams() throws {
        let payload = #"{"jsonrpc":"2.0","id":"1","method":"system.identify","params":{}}"#

        let request = try JSONRPCCodec.decodeRequest(payload)

        #expect(request.id == .string("1"))
        #expect(request.method == "system.identify")
        #expect(request.params == .object([:]))
    }

    @Test("encodes client requests and decodes responses")
    func encodesClientRequestsAndDecodesResponses() throws {
        let request = try JSONRPCClientRequest(
            id: .number(7),
            method: "terminal.wait",
            params: .object(["condition": .string("commandFinished")])
        )

        let encodedRequest = try JSONRPCCodec.encodeRequest(request)
        let decodedRequest = try JSONRPCCodec.decodeRequest(encodedRequest)
        let encodedResponse = try JSONRPCCodec.encodeResponse(
            .success(id: .number(7), result: .object(["ok": .bool(true)]))
        )
        let decodedResponse = try JSONRPCCodec.decodeResponse(encodedResponse)

        #expect(decodedRequest.id == .number(7))
        #expect(decodedRequest.method == "terminal.wait")
        #expect(decodedResponse.id == .number(7))
        #expect(decodedResponse.result == .object(["ok": .bool(true)]))
    }

    @Test("rejects batch arrays")
    func rejectsBatchArrays() throws {
        let payload = #"[{"jsonrpc":"2.0","id":"1","method":"system.identify","params":{}}]"#

        #expect(throws: JSONRPCError.self) {
            try JSONRPCCodec.decodeRequest(payload)
        }
    }

    @Test("rejects params that are not objects")
    func rejectsNonObjectParams() throws {
        let payload = #"{"jsonrpc":"2.0","id":"1","method":"system.identify","params":[]}"#

        #expect(throws: JSONRPCError.self) {
            try JSONRPCCodec.decodeRequest(payload)
        }
    }

    @Test("rejects out-of-range numeric ids without trapping")
    func rejectsOutOfRangeNumericIdsWithoutTrapping() throws {
        let payload = #"{"jsonrpc":"2.0","id":1e100,"method":"system.identify","params":{}}"#

        #expect(throws: JSONRPCError.self) {
            try JSONRPCCodec.decodeRequest(payload)
        }
    }

    @Test("rejects the rounded numeric upper boundary without crashing a decoder subprocess")
    func rejectsRoundedNumericUpperBoundaryWithoutCrashingDecoderSubprocess() async throws {
        guard ProcessInfo.processInfo.environment["AGENTSTUDIO_JSONRPC_CODEC_UPPER_BOUNDARY_PROBE"] == nil else {
            return
        }
        let payload = #"{"jsonrpc":"2.0","id":9223372036854775808,"method":"system.identify","params":{}}"#

        let result = try await decodeRequestInChildProcess(payload)

        #expect(result.standardError.contains("jsonrpc-upper-boundary-probe"))
        #expect(result.terminationReason == .exit)
        #expect(result.exitStatus == 0)
    }

    @Test("accepts exactly representable numeric identifier boundaries")
    func acceptsExactlyRepresentableNumericIdentifierBoundaries() throws {
        let lowerPayload = #"{"jsonrpc":"2.0","id":-9223372036854775808,"method":"system.identify","params":{}}"#
        let upperPayload = #"{"jsonrpc":"2.0","id":9223372036854774784,"method":"system.identify","params":{}}"#

        let lowerRequest = try JSONRPCCodec.decodeRequest(lowerPayload)
        let upperRequest = try JSONRPCCodec.decodeRequest(upperPayload)

        #expect(lowerRequest.id == .number(Int.min))
        #expect(upperRequest.id == .number(9_223_372_036_854_774_784))
    }

    @Test("preserves string and null identifiers while rejecting fractional nonfinite and out-of-range numbers")
    func preservesIdentifierGrammarAtNumericBoundaries() throws {
        let stringPayload = #"{"jsonrpc":"2.0","id":"request-1","method":"system.identify","params":{}}"#
        let nullPayload = #"{"jsonrpc":"2.0","id":null,"method":"system.identify","params":{}}"#

        #expect(try JSONRPCCodec.decodeRequest(stringPayload).id == .string("request-1"))
        #expect(try JSONRPCCodec.decodeRequest(nullPayload).id == .null)
        for rejectedPayload in [
            #"{"jsonrpc":"2.0","id":1.5,"method":"system.identify","params":{}}"#,
            #"{"jsonrpc":"2.0","id":1e100,"method":"system.identify","params":{}}"#,
            #"{"jsonrpc":"2.0","id":1e400,"method":"system.identify","params":{}}"#,
        ] {
            #expect(throws: JSONRPCError.self) {
                try JSONRPCCodec.decodeRequest(rejectedPayload)
            }
        }
    }

    @Test("runs the numeric upper-boundary decoder probe only in its isolated child process")
    func runsNumericUpperBoundaryDecoderProbe() throws {
        guard ProcessInfo.processInfo.environment["AGENTSTUDIO_JSONRPC_CODEC_UPPER_BOUNDARY_PROBE"] == "1" else {
            return
        }
        let payload = #"{"jsonrpc":"2.0","id":9223372036854775808,"method":"system.identify","params":{}}"#
        FileHandle.standardError.write(Data("jsonrpc-upper-boundary-probe\n".utf8))

        #expect(throws: JSONRPCError.self) {
            try JSONRPCCodec.decodeRequest(payload)
        }
    }

    @Test("rejects requests over the configured byte limit")
    func rejectsRequestsOverByteLimit() throws {
        let payload = #"{"jsonrpc":"2.0","id":"1","method":"system.identify","params":{}}"#

        #expect(throws: JSONRPCError.self) {
            try JSONRPCCodec.decodeRequest(payload, maxBytes: 8)
        }
    }

    @Test("encodes success responses with result and no error")
    func encodesSuccessResponseWithResultOnly() throws {
        let response = JSONRPCResponse.success(
            id: .string("1"),
            result: .object(["runtimeId": .string("runtime-1")])
        )

        let encoded = try JSONRPCCodec.encodeResponse(response)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any])

        #expect(object["jsonrpc"] as? String == "2.0")
        #expect(object["id"] as? String == "1")
        #expect(object["error"] == nil)
        #expect((object["result"] as? [String: Any])?["runtimeId"] as? String == "runtime-1")
    }

    @Test("rejects responses that include both result and error")
    func rejectsResponseWithResultAndError() throws {
        #expect(throws: JSONRPCError.self) {
            try JSONRPCResponse(
                id: .string("1"),
                result: .object([:]),
                error: JSONRPCErrorPayload(code: -32_000, message: "failed")
            )
        }
    }

    @Test("supports the JSON-RPC application error-code range")
    func supportsApplicationErrorCodeRange() throws {
        let payload = try JSONRPCErrorPayload.application(code: -32_042, message: "permission denied")
        let response = JSONRPCResponse.failure(id: .string("1"), error: payload)

        let encoded = try JSONRPCCodec.encodeResponse(response)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any])
        let error = try #require(object["error"] as? [String: Any])

        #expect(error["code"] as? Int == -32_042)
        #expect(error["message"] as? String == "permission denied")
    }

    @Test("encodes server notifications without an id")
    func encodesServerNotificationsWithoutAnId() throws {
        let notification = try JSONRPCNotification(
            method: "events.notification",
            params: .object(["name": .string("terminal.commandFinished")])
        )

        let encoded = try JSONRPCCodec.encodeNotification(notification)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any])

        #expect(object["jsonrpc"] as? String == "2.0")
        #expect(object["method"] as? String == "events.notification")
        #expect(object["id"] == nil)
        #expect((object["params"] as? [String: Any])?["name"] as? String == "terminal.commandFinished")
    }

    @Test("rejects error codes outside the application range")
    func rejectsApplicationErrorCodeOutsideRange() throws {
        #expect(throws: JSONRPCError.self) {
            try JSONRPCErrorPayload.application(code: -32_100, message: "too low")
        }
    }
}

private struct DecoderChildProcessResult {
    let exitStatus: Int32
    let terminationReason: Process.TerminationReason
    let standardError: String
}

/// Runs the probe in a child test process and suspends until it exits, with no time limit: the
/// verdict is the child's exit and stderr, never how fast a loaded runner schedules it. The exit
/// arrives through `terminationHandler`, so no thread is parked, and stderr goes to a file so a
/// crash report cannot fill a pipe the parent only reads after exit. This target cannot see
/// `AgentStudioTestSupport`, so `AgentStudioTestHarness` owns the shared cancellable wait.
private func decodeRequestInChildProcess(_ payload: String) async throws -> DecoderChildProcessResult {
    let process = Process()
    let testExecutableURL = try currentTestExecutableURL()
    let buildDirectory = try #require(ProcessInfo.processInfo.environment["SWIFT_BUILD_DIR"])
    let captureDirectory = try FileManager.default.url(
        for: .itemReplacementDirectory,
        in: .userDomainMask,
        appropriateFor: FileManager.default.temporaryDirectory,
        create: true
    )
    defer { try? FileManager.default.removeItem(at: captureDirectory) }
    let standardErrorURL = captureDirectory.appending(path: "stderr")
    FileManager.default.createFile(atPath: standardErrorURL.path, contents: nil)
    let standardErrorHandle = try FileHandle(forWritingTo: standardErrorURL)
    defer { try? standardErrorHandle.close() }
    process.executableURL = try currentSwiftPMTestingHelperURL()
    process.arguments = [
        "--test-bundle-path", testExecutableURL.path,
        "--skip-build",
        "--filter", "JSONRPCCodecTests",
        "--build-path", buildDirectory,
        testExecutableURL.path,
        "--testing-library", "swift-testing",
    ]
    process.standardError = standardErrorHandle
    process.environment = ProcessInfo.processInfo.environment.merging(
        ["AGENTSTUDIO_JSONRPC_CODEC_UPPER_BOUNDARY_PROBE": "1"]
    ) { _, newValue in newValue }
    let exitStatus = try await awaitProcessExit(process)
    return .init(
        exitStatus: exitStatus,
        terminationReason: process.terminationReason,
        standardError: String(data: try Data(contentsOf: standardErrorURL), encoding: .utf8) ?? ""
    )
}

private enum JSONRPCCodecChildProcessError: Error {
    case swiftToolchainLookupFailed
    case testExecutableUnavailable
    case testingHelperUnavailable
}

private func currentSwiftPMTestingHelperURL() throws -> URL {
    let process = Process()
    let standardOutput = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["--find", "swift"]
    process.standardOutput = standardOutput
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0,
        let swiftPath = String(
            data: standardOutput.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines),
        !swiftPath.isEmpty
    else {
        throw JSONRPCCodecChildProcessError.swiftToolchainLookupFailed
    }
    let helperURL = URL(fileURLWithPath: swiftPath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "usr/libexec/swift/pm/swiftpm-testing-helper")
    guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
        throw JSONRPCCodecChildProcessError.testingHelperUnavailable
    }
    return helperURL
}

private func currentTestExecutableURL() throws -> URL {
    let buildDirectory = try #require(ProcessInfo.processInfo.environment["SWIFT_BUILD_DIR"])
    let buildRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appending(path: buildDirectory, directoryHint: .isDirectory)
    let executableURL =
        buildRoot
        .appending(path: "debug/AgentStudioIPCTransportTests.xctest/Contents/MacOS/AgentStudioIPCTransportTests")
    guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
        throw JSONRPCCodecChildProcessError.testExecutableUnavailable
    }
    return executableURL
}
