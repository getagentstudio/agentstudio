import Foundation

package struct SessionsOpenAskUpdate: Sendable, Equatable {
    package let bindingGenerationId: UUID
    package let summary: OpenAskSummary

    package init(bindingGenerationId: UUID, summary: OpenAskSummary) {
        self.bindingGenerationId = bindingGenerationId
        self.summary = summary
    }
}

package protocol SessionOpenAskInput: Sendable {
    func receiveOpenAskSummary(_ update: SessionsOpenAskUpdate) async
}

package protocol SessionOpenAskReading: Sendable {
    func openAskSummaries() async throws -> [SessionsOpenAskUpdate]
}

/// The named producer boundary until PaneContextService supplies its committed summaries.
package struct EmptySessionOpenAskSource: SessionOpenAskReading {
    package init() {}
    package func openAskSummaries() async -> [SessionsOpenAskUpdate] { [] }
}
