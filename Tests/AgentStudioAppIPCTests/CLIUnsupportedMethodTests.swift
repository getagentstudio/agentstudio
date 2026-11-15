import AgentStudioAppIPC
import AgentStudioIPCClientCore
import Foundation
import Testing

/// A CLI newer than the running app: the app has no such method. The CLI must
/// say the running app doesn't support it, not print a bare rejection.
@Suite("CLI against an app that lacks the method")
struct CLIUnsupportedMethodTests {
    @Test("a method the running app lacks is named as unsupported by that app")
    func methodTheRunningAppLacksIsNamedUnsupported() async throws {
        // Arrange and act: a real server built without system.identify.
        let outcome = try await withLiveServer(
            makeFixture: { try LiveServerFixture(omittedMethods: ["system.identify"]) },
            body: { fixture in
                try fixture.server.start()
                return await runClientCommandLineOffCooperativePool(
                    arguments: ["system.identify"],
                    environment: [
                        "AGENTSTUDIO_IPC_SOCKET": fixture.paths.socketURL.path,
                        "AGENTSTUDIO_PANE_TOKEN": fixture.installDebugCredential().rawValue,
                    ])
            })

        // Assert
        let refusal = try #require(
            try JSONSerialization.jsonObject(with: Data(outcome.standardError.utf8)) as? [String: Any],
            "stderr: \(outcome.standardError)")
        #expect(outcome.exitCode != 0)
        #expect(refusal["reason"] as? String == "unknownMethod", "stderr: \(outcome.standardError)")
        #expect(refusal["fieldPath"] as? String == "$.method")
        #expect((refusal["expected"] as? String)?.contains("running Agent Studio") == true)
    }
}
