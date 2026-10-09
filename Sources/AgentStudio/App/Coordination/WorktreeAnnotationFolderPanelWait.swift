import AgentStudioBridge
import AppKit
import Foundation

private final class WorktreeAnnotationPickerCloseLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

@MainActor
final class WorktreeAnnotationFolderPanelWait {
    private enum State {
        case notStarted
        case waiting
        case settled(WorktreeAnnotationOutputDestinationOutcome)
    }

    private var state = State.notStarted
    private var continuation: CheckedContinuation<WorktreeAnnotationOutputDestinationOutcome, Never>?
    private let panel: any WorktreeAnnotationJSONFolderPanel
    private let preference: any WorktreeAnnotationOutputFolderPreference
    private let productAdmission: BridgeProductAdmissionContext
    private let closeLatch = WorktreeAnnotationPickerCloseLatch()
    private var closeObservation: BridgeProductAdmissionCloseObservation?

    init(
        panel: any WorktreeAnnotationJSONFolderPanel,
        preference: any WorktreeAnnotationOutputFolderPreference,
        productAdmission: BridgeProductAdmissionContext
    ) {
        self.panel = panel
        self.preference = preference
        self.productAdmission = productAdmission
    }

    func observeClose() {
        let latch = closeLatch
        closeObservation = productAdmission.observeClose { [weak self] in
            latch.cancel()
            Task { @MainActor in self?.cancel() }
        }
    }

    nonisolated func latchCancellation() {
        closeLatch.cancel()
        Task { @MainActor [weak self] in self?.cancel() }
    }

    func install(_ continuation: CheckedContinuation<WorktreeAnnotationOutputDestinationOutcome, Never>) {
        if case .settled(let outcome) = state {
            continuation.resume(returning: outcome)
            closeObservation?.cancel()
            return
        }
        self.continuation = continuation
        let mayLaunch =
            productAdmission.withValidAdmission {
                guard !closeLatch.isCancelled, !Task.isCancelled else { return false }
                state = .waiting
                return true
            } == true
        guard mayLaunch else {
            settle(.cancelled)
            return
        }
        // Launch was admitted. No locks, suspension, or second admission check before AppKit.
        panel.begin { [weak self] response in
            Task { @MainActor in self?.complete(response) }
        }
    }

    func cancel() {
        switch state {
        case .settled: return
        case .notStarted: settle(.cancelled)
        case .waiting:
            // Settle before AppKit can synchronously invoke a late completion.
            settle(.cancelled)
            panel.cancel(nil)
        }
    }

    private func complete(_ response: NSApplication.ModalResponse) {
        guard case .waiting = state else { return }
        guard response == .OK else {
            settle(.cancelled)
            return
        }
        let accepted: WorktreeAnnotationOutputDestinationOutcome? = productAdmission.withValidAdmission {
            guard !closeLatch.isCancelled else { return .cancelled }
            guard let folder = panel.url else { return .failed("The folder picker returned no folder.") }
            preference.folderURL = folder
            return .selected(path: folder.path)
        }
        settle(accepted ?? .cancelled)
    }

    private func settle(_ outcome: WorktreeAnnotationOutputDestinationOutcome) {
        guard case .settled = state else {
            state = .settled(outcome)
            closeObservation?.cancel()
            closeObservation = nil
            let reply = continuation
            continuation = nil
            reply?.resume(returning: outcome)
            return
        }
    }
}
