import AgentStudioBridge
import AgentStudioInfrastructure
import AppKit
import Foundation
import Security
import SwiftUI
import WebKit

@MainActor
enum BridgeProductStreamWebKitFeasibilityDiagnostic {
    private static var retainedPage: WebPage?
    private static var diagnosticInvocationStarted = false

    static func run(
        workerSource: String,
        timeout: Duration,
        configuration: BridgeProductStreamWebKitFeasibilityConfiguration = .productContract
    ) async -> BridgeProductStreamWebKitFeasibilityProof {
        guard !diagnosticInvocationStarted else {
            return diagnosticAlreadyStartedProof()
        }
        diagnosticInvocationStarted = true

        let expectedCapability = mintCapabilityHeader()
        let oracle = BridgeProductStreamWebKitFeasibilityOracle(configuration: configuration)
        let handler = BridgeProductStreamWebKitFeasibilitySchemeHandler(
            expectedCapability: expectedCapability,
            workerSource: workerSource,
            oracle: oracle,
            configuration: configuration
        )
        var webPageConfiguration = WebPage.Configuration()
        webPageConfiguration.websiteDataStore = .nonPersistent()
        webPageConfiguration.urlSchemeHandlers[URLScheme("agentstudio")!] = handler
        let page = WebPage(
            configuration: webPageConfiguration,
            navigationDecider: BridgeNavigationDecider(),
            dialogPresenter: WebviewDialogHandler()
        )
        let window = makeHostedWebViewWindow(page: page)

        _ = page.load(URL(string: "agentstudio://s2a/index.html")!)
        let pageReady = await waitUntil(timeout: timeout) {
            !page.isLoading && page.title == "S2a Ready"
        }
        guard pageReady else {
            retainAfterStopping(page, window: window)
            var proof = await oracle.proof(timedOut: true)
            proof.recordDiagnosticPhase(.navigationPending)
            return proof
        }

        do {
            _ = try await page.callJavaScript(
                """
                window.runBridgeProductStreamS2aProbe(
                  capability,
                  maxRequestBodyBytes,
                  nearCapWarmupRequestCount,
                  nearCapMeasuredRequestCount
                );
                return true;
                """,
                arguments: [
                    "capability": expectedCapability,
                    "maxRequestBodyBytes": configuration.maximumRequestBodyBytes,
                    "nearCapWarmupRequestCount": configuration.nearCapWarmupRequestCount,
                    "nearCapMeasuredRequestCount": configuration.nearCapMeasuredRequestCount,
                ]
            )
        } catch {
            retainAfterStopping(page, window: window)
            var proof = await oracle.proof(timedOut: true)
            proof.recordDiagnosticPhase(.scriptInvocationFailed)
            return proof
        }

        let workerSettled = await waitUntil(timeout: timeout) {
            if page.title == "S2a Fail" { return true }
            guard page.title == "S2a Pass" else { return false }
            return await oracle.recordWorkerResultAcknowledged()
        }
        let oracleComplete = await oracle.isComplete()
        let completed = workerSettled && page.title == "S2a Pass" && oracleComplete
        var proof = await oracle.proof(timedOut: !workerSettled)
        retainAfterStopping(page, window: window)
        guard completed else {
            let phase: BridgeProductStreamWebKitFeasibilityProof.DiagnosticPhase
            if page.title == "S2a Fail" {
                phase = .pageReportedFailure(origin: .unknown)
            } else if page.title == "S2a Pass" {
                phase = .pageReportedCompletion(succeeded: true)
            } else if proof.workerStartPostObserved {
                phase = .workerProgress(
                    workerStarted: true,
                    measuredRequestsAdmitted: proof.measuredRequestsAdmitted
                )
            } else {
                phase = .scriptInvoked
            }
            proof.recordDiagnosticPhase(
                phase,
                failureReasonIfNone: "worker_result_not_acknowledged"
            )
            return proof
        }
        proof.recordDiagnosticPhase(.pageReportedCompletion(succeeded: true))
        return proof
    }

    private static func waitUntil(
        timeout: Duration,
        condition: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() {
                return true
            }
            await Task.yield()
        }
        return await condition()
    }

    private static func makeHostedWebViewWindow(page: WebPage) -> NSWindow {
        let frame = NSRect(x: 0, y: 0, width: 320, height: 240)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let hostingView = NSHostingView(
            rootView: WebView(page).tint(AppStyles.General.Accent.primaryColor))
        hostingView.frame = frame
        window.contentView = hostingView
        window.alphaValue = 0.01
        window.ignoresMouseEvents = true
        window.orderBack(nil)
        return window
    }

    static func mintCapabilityHeader() -> String {
        var capabilityBytes = [UInt8](
            repeating: 0,
            count: BridgeProductWireContract.capabilityByteLength
        )
        let randomStatus = capabilityBytes.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, buffer.count, baseAddress)
        }
        precondition(
            randomStatus == errSecSuccess,
            "Bridge product capability random generation failed with status \(randomStatus)"
        )
        guard let encodedCapability = try? BridgeProductCapabilityHeaderEncoding.encode(capabilityBytes) else {
            preconditionFailure("Bridge product capability encoding rejected its fixed-length input")
        }
        return encodedCapability
    }

    private static func diagnosticAlreadyStartedProof() -> BridgeProductStreamWebKitFeasibilityProof {
        .failed(reason: "diagnostic_already_started")
    }

    private static func retainAfterStopping(_ page: WebPage, window: NSWindow) {
        page.stopLoading()
        window.orderOut(nil)
        window.contentView = nil
        // Retain one stopped page because repeated WebPage deallocation can crash serialized WebKit tests.
        precondition(retainedPage == nil, "Bridge product stream diagnostic retained more than one page")
        retainedPage = page
    }
}
