import AgentStudioCore
import Foundation
import Observation

/// Presentation-lifetime read output, with no identity cache or status-key reuse.
@MainActor
@Observable
final class PaneManagementSessionIdentity {
    private(set) var summary: SessionSummary?
    @ObservationIgnored private var requestRevision: UInt64 = 0

    func refresh(paneId: UUID, readers: PaneContextUIReaders?) async {
        requestRevision &+= 1
        let revision = requestRevision
        summary = nil
        let session = await PaneManagementIdentityCapture.verifiedLiveSession(paneId: paneId, readers: readers)
        guard !Task.isCancelled, requestRevision == revision else { return }
        summary = session
    }

    func close() {
        requestRevision &+= 1
        summary = nil
    }
}
