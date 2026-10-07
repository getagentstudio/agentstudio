import Foundation

/// App translates this Core summary into the Sessions-owned input port.
package struct PaneContextOpenAskUpdate: Sendable, Equatable {
    package let bindingGenerationId: UUID
    package let sequence: Int64
    package let approval: Int
    package let question: Int
    package let blocked: Int

    package init(bindingGenerationId: UUID, sequence: Int64, approval: Int, question: Int, blocked: Int) {
        self.bindingGenerationId = bindingGenerationId
        self.sequence = sequence
        self.approval = approval
        self.question = question
        self.blocked = blocked
    }
}
