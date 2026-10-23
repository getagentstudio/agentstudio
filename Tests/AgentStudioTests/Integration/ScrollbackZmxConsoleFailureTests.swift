import AgentStudioTestSupport
import Foundation
import Testing

/// Independent harnesses own distinct ZMX_DIR roots; these failure cases can
/// run concurrently and share no app state or terminal session.
@Suite("Scrollback console producer failures")
struct ScrollbackZmxConsoleFailureTests {
    @Test("a producer exiting before its first marker ends make with the observed output")
    func producerExitBeforeFirstMarkerEndsMake() async throws {
        let harness = await ZmxTestHarness()
        let pipe = Pipe()
        defer {
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }
        var bodyError: (any Error)?
        do {
            let console = try await ScrollbackZmxConsole.make(
                harness: harness, producerLifetime: .exitsBeforeFirstMarker, outputPipe: pipe)
            console.closeHandles()
            Issue.record("An exited producer cannot satisfy the first console marker")
        } catch let failure as ScrollbackConsoleFailure {
            switch failure {
            case .outputEndedBeforeMarker(let marker, let observed):
                #expect(marker.contains(Data("-one".utf8)))
                #expect(observed.contains(Data("partial output before first marker".utf8)))
                #expect(failure.localizedDescription.contains("marker"))
            case .producerExitedBeforeFIFO:
                Issue.record("The producer reached the start FIFO; its missing first marker must name EOF")
            }
        } catch { bodyError = error }
        let cleanup = await harness.cleanup()
        #expect(cleanup.succeeded, Comment(rawValue: cleanup.diagnostics))
        #expect(cleanup.remainingSessionNames.isEmpty)
        if let bodyError { throw bodyError }
    }

    @Test("a producer exiting before the redraw FIFO ends the rendezvous")
    func producerExitBeforeRedrawFIFOEndsRendezvous() async throws {
        let harness = await ZmxTestHarness()
        var console: ScrollbackZmxConsole?
        var bodyError: (any Error)?
        do {
            let terminal = try await ScrollbackZmxConsole.make(
                harness: harness, producerLifetime: .exitsBeforeRedraw)
            console = terminal
            let status = try await terminal.endProducerBeforeRedraw()
            #expect(!terminal.producer.isRunning, "Fixture producer must have exited; status \(status)")
            do {
                try await terminal.redrawInPlace()
                Issue.record("An exited producer cannot receive a redraw FIFO release")
            } catch let failure as ScrollbackConsoleFailure {
                switch failure {
                case .producerExitedBeforeFIFO(let name):
                    #expect(name.contains("redraw"))
                    #expect(failure.localizedDescription.contains("FIFO rendezvous"))
                case .outputEndedBeforeMarker:
                    Issue.record("The dead producer must end the FIFO rendezvous before any marker read")
                }
            }
        } catch { bodyError = error }
        let cleanup = await harness.cleanup()
        console?.closeHandles()
        #expect(cleanup.succeeded, Comment(rawValue: cleanup.diagnostics))
        #expect(cleanup.remainingSessionNames.isEmpty)
        if let bodyError { throw bodyError }
    }
}
