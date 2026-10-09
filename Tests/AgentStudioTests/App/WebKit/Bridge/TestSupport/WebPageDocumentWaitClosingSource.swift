import AgentStudioInfrastructure
import AgentStudioTestHarness
import Foundation
import WebKit

@testable import AgentStudioBridge

struct WebPageDocumentWaitScope: Hashable, Sendable {
    let pane: String
    let requestId: String?
}

enum WebPageDocumentWaitCloseReason: Sendable {
    case failedStart
    case pageClosed
    case webContentProcessTerminated
    case navigationFailed(String)
    case navigationEnded
    case cancelled

    var description: String {
        switch self {
        case .failedStart: "failedStart"
        case .pageClosed: "pageClosed"
        case .webContentProcessTerminated: "webContentProcessTerminated"
        case .navigationFailed(let error): "navigation failed: \(error)"
        case .navigationEnded: "navigation stream ended"
        case .cancelled: "wait cancelled"
        }
    }

    var requiresPageAbort: Bool {
        if case .webContentProcessTerminated = self { return false }
        return true
    }
}

struct WebPageDocumentWaitClosure: Sendable {
    let scope: WebPageDocumentWaitScope
    let reason: WebPageDocumentWaitCloseReason

    func named(_ milestone: String, bootstrapDiagnostics: String? = nil) -> WebPageDocumentWaitOwnerFailure {
        WebPageDocumentWaitOwnerFailure(closure: self, milestone: milestone, bootstrapDiagnostics: bootstrapDiagnostics)
    }
}

struct WebPageDocumentWaitOwnerFailure: Error, Sendable, CustomStringConvertible {
    let closure: WebPageDocumentWaitClosure
    let milestone: String
    let bootstrapDiagnostics: String?

    var description: String {
        "GO26 pane=\(closure.scope.pane) milestone=\(milestone) requestId=\(closure.scope.requestId ?? "none") reason=\(closure.reason.description)"
            + (bootstrapDiagnostics.map { "; " + $0 } ?? "")
    }
}

/// Keeps terminal navigation facts separate from retryable bootstrap diagnostics.
@MainActor
final class WebPageDocumentWaitClosingSource {
    let pane: String
    private(set) var firstClosure: WebPageDocumentWaitClosure?
    private(set) var bootstrapFailureCount = 0
    private(set) var lastBootstrapFailure: BridgeProductSessionBootstrapFailureReason?

    var bootstrapDiagnostics: String {
        "bootstrap failed \(bootstrapFailureCount) times, last=\(lastBootstrapFailure?.rawValue ?? "none")"
    }
    private let source: LocalFactSource<WebPageDocumentWaitScope, WebPageDocumentWaitCloseReason>
    let recorder: FactRecorder<WebPageDocumentWaitScope, WebPageDocumentWaitCloseReason>
    private var observers: [UUID: @MainActor (WebPageDocumentWaitWake) -> Void] = [:]
    private var navigationTask: Task<Void, Never>?

    init(pane: String) throws {
        self.pane = pane
        source = LocalFactSource(
            vocabulary: .init(
                describeScope: { "pane=\($0.pane) requestId=\($0.requestId ?? "none")" },
                describeFact: { $0.description }, isClosing: { _, _ in true }))
        recorder = try source.attach()
    }

    func record(_ reason: WebPageDocumentWaitCloseReason, requestId: String? = nil) {
        guard firstClosure == nil else { return }
        let closure = WebPageDocumentWaitClosure(scope: .init(pane: pane, requestId: requestId), reason: reason)
        firstClosure = closure
        source.sink(closure.scope, closure.reason)
        for observer in observers.values { observer(.closed(closure)) }
    }

    func recordBootstrapFailure(_ reason: BridgeProductSessionBootstrapFailureReason) {
        bootstrapFailureCount += 1
        lastBootstrapFailure = reason
        for observer in observers.values { observer(.diagnosticsUpdated) }
    }

    func observe(_ observer: @escaping @MainActor (WebPageDocumentWaitWake) -> Void) -> UUID {
        let observationId = UUIDv7.generate()
        observers[observationId] = observer
        if let firstClosure { observer(.closed(firstClosure)) }
        return observationId
    }

    func removeObservation(_ observationId: UUID) { observers.removeValue(forKey: observationId) }

    func observePage(_ page: WebPage) {
        precondition(navigationTask == nil)
        // Property access attaches the indefinite sequence synchronously, before loadApp.
        let navigations = page.navigations
        navigationTask = Task { @MainActor in
            do {
                for try await _ in navigations {}
                if !Task.isCancelled { record(.navigationEnded) }
            } catch {
                guard !Task.isCancelled else { return }
                switch error as? WebPage.NavigationError {
                case .some(.webContentProcessTerminated): record(.webContentProcessTerminated)
                case .some(.pageClosed): record(.pageClosed)
                default: record(.navigationFailed(String(describing: error)))
                }
            }
        }
    }

    func requireMountedApp(_ controller: BridgePaneController) async throws -> BridgeProductWebKitCarrierNativeSnapshot
    {
        await WebPageEventWaits.waitForNavigationToFinish(controller.page)
        try await WebPageEventWaits.waitForDocumentSelector(
            controller.page,
            "[data-testid=\"bridge-app-root\"]", closingSource: self, milestone: "bundled app mounted"
        )
        await WebPageEventWaits.waitForBridgeReady(controller)
        guard let installation = await controller.productSessionOwner.activeInstallation,
            await installation.session.waitUntilActive()
        else {
            throw BridgeProductWebKitTwoPaneJourneyTestSupport.JourneyError.conditionFailed(
                "bundled app native session did not activate")
        }
        let native = await BridgeProductWebKitCarrierTestSupport.nativeSnapshot(controller)
        guard native.lifecycle == "active" else {
            throw BridgeProductWebKitTwoPaneJourneyTestSupport.JourneyError.conditionFailed(
                "bundled app native session was not active")
        }
        return native
    }

    func activateReadyFileMode(
        _ controller: BridgePaneController,
        failure: String
    ) async throws {
        guard await BridgeProductWebKitCarrierTestSupport.activateFileMode(controller.page) else {
            throw BridgeProductWebKitTwoPaneJourneyTestSupport.JourneyError.conditionFailed(failure)
        }
        _ = try await WebPageEventWaits.waitForDocumentValue(
            controller.page,
            reader: """
                const shell = document.querySelector('[data-testid="bridge-file-viewer-shell"]');
                const count = Number(shell?.getAttribute('data-file-display-item-count') ?? '0');
                return shell?.getAttribute('data-file-display-status') === 'ready'
                  && count > 0 ? count : null;
                """, milestone: "File display ready with nonempty items", closingSource: self
        )
    }

    func finish() async throws {
        navigationTask?.cancel()
        await navigationTask?.value
        navigationTask = nil
        observers.removeAll()
        source.end()
        try await recorder.finish()
    }
}

enum WebPageDocumentWaitWake: Sendable {
    case documentCompleted
    case diagnosticsUpdated
    case closed(WebPageDocumentWaitClosure)
    case cancelled
}
