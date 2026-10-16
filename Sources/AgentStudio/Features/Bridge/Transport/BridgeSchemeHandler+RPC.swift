import Foundation
import WebKit
import os.log

private let bridgeProductSchemeTaskLogger = Logger(
    subsystem: "com.agentstudio",
    category: "BridgeProductSchemeTask"
)

extension BridgeSchemeHandler.PathType {
    var supportsPostRequests: Bool {
        switch self {
        case .telemetryBatch, .product:
            true
        case .app, .invalid:
            false
        }
    }
}

extension BridgeSchemeHandler {
    func startProductReplyTask(
        request: URLRequest,
        continuation: AsyncThrowingStream<URLSchemeTaskResult, any Error>.Continuation
    ) {
        let route = request.url?.absoluteString ?? "missing-url"
        // Minted here, before the task, so the census entry and the transport
        // claim are one identity and `onTermination` can mark an id that the
        // claim will later finish.
        let schemeTaskId = UUID()
        let schemeRoute = request.url.flatMap(BridgeProductSchemeRoute.classify)
        let census = productSessionRouter?.schemeTaskCensus
        if schemeRoute == .metadataStream {
            census?.start(schemeTaskId)
        }
        let task = Task {
            // One exit point for the census: every early return below unwinds
            // through this, so no path can leave a started id behind.
            defer {
                if schemeRoute == .metadataStream {
                    census?.finish(schemeTaskId)
                }
            }
            bridgeProductSchemeTaskLogger.debug("Product scheme task started route=\(route, privacy: .public)")
            guard !Task.isCancelled else {
                bridgeProductSchemeTaskLogger.debug(
                    "Product scheme task cancelled before claim route=\(route, privacy: .public)"
                )
                continuation.finish(throwing: CancellationError())
                return
            }
            guard let url = request.url else {
                // WKURLSchemeTask always has a URL. Without one there is no
                // legal response target, and WebKit must not see a generic error.
                continuation.finish(throwing: CancellationError())
                return
            }
            guard
                let presentedCapability = request.value(
                    forHTTPHeaderField: BridgeProductWireContract.capabilityHeaderName
                )
            else {
                emitProductAdmissionResponse(
                    statusCode: 401,
                    url: url,
                    continuation: continuation
                )
                return
            }
            guard let productSessionRouter else {
                bridgeProductSchemeTaskLogger.error(
                    "Product scheme task rejected without active session route=\(route, privacy: .public)"
                )
                emitProductAdmissionResponse(
                    statusCode: 503,
                    url: url,
                    continuation: continuation
                )
                return
            }
            let transportAdmission = await productSessionRouter.claimActiveAdapter(
                presentedCapability: presentedCapability,
                schemeTaskId: schemeTaskId,
                route: schemeRoute
            )
            let transportClaim: BridgeProductSchemeTransportClaim
            switch transportAdmission {
            case .admitted(let admittedClaim):
                transportClaim = admittedClaim
            case .conflict:
                emitProductAdmissionResponse(
                    statusCode: 409,
                    url: url,
                    continuation: continuation
                )
                return
            case .unauthorized:
                emitProductAdmissionResponse(
                    statusCode: 403,
                    url: url,
                    continuation: continuation
                )
                return
            }
            guard !Task.isCancelled else {
                bridgeProductSchemeTaskLogger.debug(
                    "Product scheme task cancelled after claim route=\(route, privacy: .public)"
                )
                continuation.finish(throwing: CancellationError())
                await transportClaim.finish()
                return
            }
            await transportClaim.route(
                request,
                continuation: continuation
            )
            bridgeProductSchemeTaskLogger.debug(
                "Product scheme task completed route=\(route, privacy: .public)"
            )
            await transportClaim.finish()
        }
        continuation.onTermination = { termination in
            bridgeProductSchemeTaskLogger.debug(
                "Product scheme consumer terminated route=\(route, privacy: .public) termination=\(String(describing: termination), privacy: .public)"
            )
            Self.recordSchemeTaskTermination(
                census: schemeRoute == .metadataStream ? census : nil,
                schemeTaskId: schemeTaskId,
                cancel: { task.cancel() }
            )
        }
    }

    /// Marks the stream's teardown before cancelling it, so the bootstrap gate can
    /// tell "this stream is dead, its retirement has simply not been written yet"
    /// from "this stream is live".
    private static func recordSchemeTaskTermination(
        census: BridgeProductSchemeTaskCensus?,
        schemeTaskId: UUID,
        cancel: @escaping @Sendable () -> Void
    ) {
        guard let census else {
            cancel()
            return
        }
        census.markTerminated(schemeTaskId)
        guard census.holdsTerminationObserver else {
            // Production path: cancellation stays exactly as synchronous as before.
            cancel()
            return
        }
        // Tests only, and only when an observer was supplied.
        Task {
            await census.awaitTerminationObserver(schemeTaskId)
            cancel()
        }
    }

    private func emitProductAdmissionResponse(
        statusCode: Int,
        url: URL,
        continuation: AsyncThrowingStream<URLSchemeTaskResult, any Error>.Continuation
    ) {
        continuation.yield(
            .response(
                Self.response(
                    url: url,
                    mimeType: "application/json",
                    expectedContentLength: 0,
                    allowedMethods: "OPTIONS, POST",
                    allowedHeaders:
                        "Content-Type, \(BridgeProductWireContract.capabilityHeaderName)",
                    statusCode: statusCode
                )
            )
        )
        continuation.finish()
    }
}
