import Foundation
import Testing

@testable import AgentStudioCore

extension PaneContextPresentationRulesTests {
    @Test("G11 an eight-day-old stored Agent Line remains intact and scheduled until cleared or replaced")
    func storedLineHasNoExpiry() async throws {
        try await withPaneContextService { fixture, service in
            let epoch = try await fixture.epoch(service, stream: .line)
            try #require(await service.setLine(fixture.line("Still here", epoch: epoch, counter: 1)) == .applied)
            let original = try #require(try await fixture.detail(service).agentLine)
            fixture.time.shiftWallTime(by: 8 * 86_400)

            let retained = try #require(try await fixture.detail(service).agentLine)
            #expect(retained == original)
            #expect(retained.summary == "Still here")
            #expect(retained.writer == fixture.sender)
            let age = PaneContextPresentationRules.age(referenceDate: retained.updatedAt, now: fixture.time.now)
            #expect(age.text == "8 days ago")
            #expect(age.nextChange == retained.updatedAt.addingTimeInterval(9 * 86_400))
            #expect(age.nextChange > fixture.time.now)
            #expect(
                PaneContextPresentationRules.toolbarSelection(counts: .zero, agentLine: retained, now: fixture.time.now)
                    == .agentLine(text: "Still here", age: age))

            try #require(await service.setLine(fixture.line(nil, epoch: epoch, counter: 2)) == .applied)
            #expect(try await fixture.detail(service).agentLine == nil)
            try #require(await service.setLine(fixture.line("Replacement", epoch: epoch, counter: 3)) == .applied)
            let replacement = try #require(try await fixture.detail(service).agentLine)
            #expect(replacement.summary == "Replacement")
            #expect(replacement.updatedAt == fixture.time.now)
            #expect(
                PaneContextPresentationRules.agentLineAge(referenceDate: replacement.updatedAt, now: fixture.time.now)
                    == "[Now]")
        }
    }
}
