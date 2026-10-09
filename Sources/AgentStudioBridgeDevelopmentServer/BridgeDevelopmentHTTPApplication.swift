import AgentStudioBridge
import Foundation
import HTTPTypes
import Hummingbird
import NIOCore
import WebKit

enum BridgeDevelopmentHTTPApplication {
    private static let bootstrapBodyLimit = 8 * 1024

    static func make(
        host: BridgeDevelopmentProductHost,
        configuration: ApplicationConfiguration = .init(),
        eventLoopGroupProvider: EventLoopGroupProvider = .singleton,
        healthIsReady: @escaping @Sendable () async -> Bool = { true },
        onServerRunning: @escaping @Sendable (any Channel) async -> Void = { _ in }
    ) -> some ApplicationProtocol {
        let router = Router(context: BridgeDevelopmentHTTPRequestContext.self)
        router.get("/__bridge-product/health") { _, _ -> Response in
            Response(status: await healthIsReady() ? .noContent : .serviceUnavailable)
        }
        router.post("/__bridge-product/bootstrap") { request, _ -> Response in
            try await bootstrapResponse(request: request, host: host)
        }
        registerProductRoute(
            "/__bridge-product/command",
            destination: "agentstudio://rpc/command",
            router: router,
            host: host
        )
        registerProductRoute(
            "/__bridge-product/stream",
            destination: "agentstudio://rpc/stream",
            router: router,
            host: host
        )
        registerProductRoute(
            "/__bridge-product/content",
            destination: "agentstudio://rpc/content",
            router: router,
            host: host
        )
        return Application(
            responder: router.buildResponder(),
            configuration: configuration,
            onServerRunning: onServerRunning,
            eventLoopGroupProvider: eventLoopGroupProvider
        )
    }

    private static func registerProductRoute(
        _ path: RouterPath,
        destination: String,
        router: Router<BridgeDevelopmentHTTPRequestContext>,
        host: BridgeDevelopmentProductHost
    ) {
        router.post(path) { request, context -> Response in
            let body = try await request.body.collect(upTo: BridgeProductWireContract.maximumRequestBodyBytes)
            guard let destinationURL = URL(string: destination) else {
                throw HTTPError(.internalServerError)
            }
            let forwardedRequest = forwardedProductRequest(
                destinationURL: destinationURL,
                body: Data(body.readableBytesView),
                headers: request.headers
            )
            return try await BridgeDevelopmentHTTPProductResponse.make(
                from: await host.route(forwardedRequest),
                onConnectionClose: context.onConnectionClose
            )
        }
    }

    static func forwardedProductRequest(
        destinationURL: URL,
        body: Data,
        headers: HTTPFields
    ) -> URLRequest {
        var request = URLRequest(url: destinationURL)
        request.httpMethod = "POST"
        request.httpBody = body
        if let contentType = headers[.contentType] {
            request.setValue(contentType, forHTTPHeaderField: HTTPField.Name.contentType.rawName)
        }
        if let capabilityName = HTTPField.Name(BridgeProductWireContract.capabilityHeaderName),
            let capability = headers[capabilityName]
        {
            request.setValue(capability, forHTTPHeaderField: capabilityName.rawName)
        }
        return request
    }

    private static func bootstrapResponse(
        request: Request,
        host: BridgeDevelopmentProductHost
    ) async throws -> Response {
        guard request.headers[.contentType]?.lowercased() == "application/json" else {
            throw HTTPError(.unsupportedMediaType)
        }
        let body = try await request.body.collect(upTo: bootstrapBodyLimit)
        let bootstrapRequest: BridgeDevelopmentProductBootstrapRequest
        do {
            bootstrapRequest = try JSONDecoder().decode(
                BridgeDevelopmentProductBootstrapRequest.self,
                from: Data(body.readableBytesView)
            )
        } catch {
            throw HTTPError(.badRequest)
        }
        let delivery: Data
        do {
            delivery = try await host.issueBootstrap(for: bootstrapRequest)
        } catch BridgeDevelopmentProductHostError.sessionAlreadyOpen {
            throw HTTPError(.conflict)
        }
        return Response(
            status: .ok,
            headers: [.contentType: "application/octet-stream"],
            body: .init(byteBuffer: ByteBuffer(bytes: delivery))
        )
    }
}

/// Carries the existing socket lifetime into a response that can be idle indefinitely.
/// It does not consume the request body or change finite-response keep-alive semantics.
struct BridgeDevelopmentHTTPRequestContext: RequestContext {
    var coreContext: CoreRequestContextStorage
    let onConnectionClose: @Sendable (@escaping @Sendable () -> Void) -> Void

    init(source: ApplicationRequestContextSource) {
        coreContext = .init(source: source)
        let connectionClosed = source.channel.closeFuture
        onConnectionClose = { handler in
            connectionClosed.whenComplete { _ in handler() }
        }
    }
}

enum BridgeDevelopmentHTTPProductResponse {
    static func make(
        from results: AsyncThrowingStream<URLSchemeTaskResult, any Error>,
        onConnectionClose: (@Sendable (@escaping @Sendable () -> Void) -> Void)? = nil
    ) async throws -> Response {
        let (responseHeads, responseHeadContinuation) =
            AsyncThrowingStream<HTTPURLResponse, any Error>.makeStream(
                bufferingPolicy: .bufferingNewest(1)
            )
        let (responseBody, responseBodyContinuation) =
            AsyncThrowingStream<ByteBuffer, any Error>.makeStream(
                bufferingPolicy: .unbounded
            )
        let routeTask = Task {
            do {
                var receivedResponseHead = false
                for try await result in results {
                    try Task.checkCancellation()
                    switch result {
                    case .response(let response):
                        guard !receivedResponseHead,
                            let httpResponse = response as? HTTPURLResponse
                        else {
                            throw BridgeDevelopmentHTTPResponseError.invalidResponseSequence
                        }
                        receivedResponseHead = true
                        guard case .enqueued = responseHeadContinuation.yield(httpResponse) else {
                            throw BridgeDevelopmentHTTPResponseError.invalidResponseSequence
                        }
                        responseHeadContinuation.finish()
                    case .data(let data):
                        guard receivedResponseHead else {
                            throw BridgeDevelopmentHTTPResponseError.invalidResponseSequence
                        }
                        guard
                            case .enqueued = responseBodyContinuation.yield(ByteBuffer(bytes: data))
                        else {
                            throw BridgeDevelopmentHTTPResponseError.invalidResponseSequence
                        }
                    @unknown default:
                        throw BridgeDevelopmentHTTPResponseError.invalidResponseSequence
                    }
                }
                guard receivedResponseHead else {
                    throw BridgeDevelopmentHTTPResponseError.missingResponseHead
                }
                responseBodyContinuation.finish()
            } catch {
                responseHeadContinuation.finish(throwing: error)
                responseBodyContinuation.finish(throwing: error)
            }
        }
        let responseLifetime = BridgeDevelopmentHTTPResponseLifetime(task: routeTask)
        onConnectionClose? { [weak responseLifetime] in responseLifetime?.cancel() }
        responseBodyContinuation.onTermination = { _ in routeTask.cancel() }

        var responseHeadIterator = responseHeads.makeAsyncIterator()
        guard let responseHead = try await responseHeadIterator.next() else {
            routeTask.cancel()
            throw BridgeDevelopmentHTTPResponseError.missingResponseHead
        }
        return Response(
            status: .init(code: responseHead.statusCode),
            headers: forwardedHeaders(responseHead),
            body: .init { writer in
                defer { responseLifetime.cancel() }
                do {
                    try await withTaskCancellationHandler {
                        try await writer.write(responseBody)
                        try await writer.finish(nil)
                    } onCancel: {
                        responseLifetime.cancel()
                    }
                } catch {
                    routeTask.cancel()
                    await routeTask.value
                    throw error
                }
            }
        )
    }

    private static func forwardedHeaders(_ response: HTTPURLResponse) -> HTTPFields {
        var fields = HTTPFields()
        let forwardedNames: [HTTPField.Name] = [
            .contentType,
            .accessControlAllowCredentials,
            .accessControlAllowHeaders,
            .accessControlAllowMethods,
            .accessControlAllowOrigin,
        ]
        for name in forwardedNames {
            if let value = response.value(forHTTPHeaderField: name.rawName) {
                fields[name] = value
            }
        }
        return fields
    }
}

/// The connection callback holds this weakly, so keep-alive cannot retain completed bodies.
private final class BridgeDevelopmentHTTPResponseLifetime: Sendable {
    let task: Task<Void, Never>

    init(task: Task<Void, Never>) { self.task = task }

    func cancel() { task.cancel() }

    deinit { task.cancel() }
}

private enum BridgeDevelopmentHTTPResponseError: Error {
    case invalidResponseSequence
    case missingResponseHead
}
