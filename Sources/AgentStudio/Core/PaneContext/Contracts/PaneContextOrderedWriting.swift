import Foundation

package struct WriteNumber: Sendable, Equatable {
    package let epoch: UInt64
    package let counter: UInt64

    package init(
        epoch: UInt64,
        counter: UInt64
    ) {
        self.epoch = epoch
        self.counter = counter
    }
}

package struct PaneEpochClaimRequest: Sendable, Equatable {
    package let paneId: PaneId
    package let writer: AgentMessageSender
    package let stream: PaneWriteStream
    package let claimId: UUID

    package init(
        paneId: PaneId,
        writer: AgentMessageSender,
        stream: PaneWriteStream,
        claimId: UUID
    ) {
        self.paneId = paneId
        self.writer = writer
        self.stream = stream
        self.claimId = claimId
    }
}

package struct PaneTitleWriteRequest: Sendable, Equatable {
    package let paneId: PaneId
    package let writer: AgentMessageSender
    package let text: String?
    package let writeNumber: WriteNumber

    package init(
        paneId: PaneId,
        writer: AgentMessageSender,
        text: String?,
        writeNumber: WriteNumber
    ) {
        self.paneId = paneId
        self.writer = writer
        self.text = text
        self.writeNumber = writeNumber
    }
}

package struct PaneLineWriteRequest: Sendable, Equatable {
    package let paneId: PaneId
    package let writer: AgentMessageSender
    package let line: AgentLineInput?
    package let writeNumber: WriteNumber

    package init(
        paneId: PaneId,
        writer: AgentMessageSender,
        line: AgentLineInput?,
        writeNumber: WriteNumber
    ) {
        self.paneId = paneId
        self.writer = writer
        self.line = line
        self.writeNumber = writeNumber
    }
}

package struct AgentLineInput: Sendable, Equatable {
    package let summary: String
    package let work: AgentLineWork
    package let detail: String?
    package let refs: [MessageAction]
    package let lifetime: AgentLineLifetime

    package init(
        summary: String,
        work: AgentLineWork,
        detail: String?,
        refs: [MessageAction],
        lifetime: AgentLineLifetime
    ) {
        self.summary = summary
        self.work = work
        self.detail = detail
        self.refs = refs
        self.lifetime = lifetime
    }
}

package enum PaneWriteStream: Sendable, Equatable {
    case line
    case title
}
package enum PaneEpochClaimResult: Sendable, Equatable {
    case claimed(UInt64)
    case refused(PaneContextWriteRefusal)
    case unavailable(StorageFailureSummary)
}
package enum PaneOrderedWriteResult: Sendable, Equatable {
    case applied
    case stale(PaneWriteStaleness)
    case refused(PaneContextWriteRefusal)
    case unavailable(StorageFailureSummary)
}
package enum PaneWriteStaleness: Sendable, Equatable {
    case lastAccepted(WriteNumber)
    case epochSuperseded
    case writerReplaced
}
