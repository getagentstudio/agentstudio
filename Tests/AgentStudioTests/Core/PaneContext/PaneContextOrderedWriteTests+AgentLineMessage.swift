import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioCore

extension PaneContextOrderedWriteTests {
    @Test("message metadata remains unchanged after its old expiry and writer session end")
    func agentLineMessageKeepsWriterAndTimestamp() async throws {
        try await withPaneContextService { fixture, service in
            let epoch = try await fixture.epoch(service, stream: .line)
            let request = fixture.line(
                "Retained message", epoch: epoch, counter: 1)
            try #require(await service.setLine(request) == .applied)
            let written = try #require(try await fixture.detail(service).agentLine)

            fixture.time.shiftWallTime(by: 3600)
            #expect(try await fixture.detail(service).agentLine == written)
            await service.sessionEnded(bindingGenerationId: try fixture.bindingGenerationId)
            #expect(try await fixture.detail(service).agentLine == written)
        }
    }
}
