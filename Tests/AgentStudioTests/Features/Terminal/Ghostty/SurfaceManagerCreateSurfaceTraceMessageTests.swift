import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioTerminal

/// F9 (review round 1, minor): a restore command's trailing argument is the
/// startup attempt token (PD rev 21:162, "the token never reaches logs,
/// telemetry or OTLP"). `SurfaceManager.createSurface`'s own `RestoreTrace.log`
/// call used to interpolate `metadata.command` directly, putting the full
/// command -- token included -- into the local restore trace whenever
/// `AGENTSTUDIO_RESTORE_TRACE` is enabled.
///
/// `RestoreTrace.enabled` is a `static let`, evaluated once per process from
/// `ProcessInfo.processInfo.environment` at first access, so a unit test
/// cannot toggle it after the fact and exercising the gated `log` call
/// itself isn't practical here. The fix instead extracted the message
/// construction into `SurfaceManager.createSurfaceTraceMessage(metadata:)`,
/// a pure function `RestoreTrace.log`'s argument is built from -- this suite
/// tests that function's actual behavior directly, not a source-text match
/// a differently spelled regression could still pass.
@Suite("SurfaceManager create-surface trace message")
struct SurfaceManagerCreateSurfaceTraceMessageTests {
    @Test("the message carries command presence and length, never the command text or its token")
    func messageRedactsTheCommandButKeepsPresenceAndLength() {
        // Arrange
        let startupToken = "agentstudio-restore-\(UUIDv7.generate().uuidString)"
        let command = "/bin/zsh -i -l -c 'zmx attach test-session || zmx run test-session -- \(startupToken)'"
        let metadata = SurfaceMetadata(
            command: command,
            title: "Terminal",
            paneId: UUIDv7.generate()
        )

        // Act
        let message = SurfaceManager.createSurfaceTraceMessage(metadata: metadata)

        // Assert
        #expect(!message.contains(startupToken), "the message must never carry the startup attempt token")
        #expect(!message.contains(command), "the message must never carry the command text at all")
        #expect(message.contains("cmdPresent=true"))
        #expect(message.contains("cmdLength=\(command.count)"))
    }

    @Test("a nil command is reported as absent with zero length")
    func nilCommandReportsAbsentWithZeroLength() {
        // Arrange
        let metadata = SurfaceMetadata(title: "Terminal", paneId: UUIDv7.generate())

        // Act
        let message = SurfaceManager.createSurfaceTraceMessage(metadata: metadata)

        // Assert
        #expect(message.contains("cmdPresent=false"))
        #expect(message.contains("cmdLength=0"))
    }
}
