import AgentStudioCore
import Foundation
import Testing

@testable import AgentStudio

extension PaneContextNativePopoverWindow {
    enum DetailReadProducer {
        case opening(Int)
        case action(Int)
    }

    /// Forwards at the reader's serialization point, so arrival cannot be
    /// reordered behind a later producer-ending observation by a helper task.
    func observeDetailReads(from ports: PaneContextPopoverTestPorts) async {
        let facts = self.facts
        await ports.observeDetailReadFacts { number, fact in
            facts.append(scope: .detailRead(number), fact: .detailRead(fact))
        }
    }

    func detailReadStarted(
        _ number: Int, request: PaneContextReadRequest, producer: DetailReadProducer
    ) async throws {
        let scope = NativePopoverScope.detailRead(number)
        guard !sink.retired else { throw NativeReadAdmissionFailure.viewRetired }
        sink.pendingReadWaitScopes.insert(scope)
        defer { sink.pendingReadWaitScopes.remove(scope) }
        let task: Task<Void, Never>
        switch producer {
        case .opening(let index):
            let announcement = NativePopoverScope.readAnnouncement(index)
            sink.pendingReadWaitScopes.insert(announcement)
            defer { sink.pendingReadWaitScopes.remove(announcement) }
            try await facts.expectNext(in: announcement, .readStarted(index))
            try #require(sink.reads.indices.contains(index), "The opening did not retain its announced task")
            task = sink.reads[index].task
        case .action(let index):
            try #require(sink.actionTasks.indices.contains(index), "The native action did not announce its task")
            task = sink.actionTasks[index]
        }
        sink.readMonitors.append(
            Task {
                await task.value
                facts.append(scope: scope, fact: .readEnded(cancelled: task.isCancelled))
            })
        try await facts.expectNext(in: scope, .detailRead(.started(request)))
    }
}

private enum NativeReadAdmissionFailure: Error { case viewRetired }
