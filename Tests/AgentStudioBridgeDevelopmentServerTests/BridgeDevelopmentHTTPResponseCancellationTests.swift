import Darwin
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import NIOCore
import Synchronization
import Testing
import WebKit

@testable import AgentStudioBridgeDevelopmentServer

@Suite("Bridge development HTTP response cancellation")
struct BridgeDevelopmentHTTPResponseCancellationTests {

    @Test("connection reset before the upstream response head cancels the waiting producer")
    func connectionResetBeforeResponseHeadCancelsUpstream() async throws {
        // Arrange — the upstream has not yielded headers or content yet.
        let probe = HTTPResponseCancellationProbe()
        let (results, continuation) = AsyncThrowingStream<URLSchemeTaskResult, any Error>.makeStream()
        continuation.onTermination = { termination in
            if case .cancelled = termination { probe.recordCancellation() }
        }
        defer { continuation.finish() }
        let router = Router(context: BridgeDevelopmentHTTPRequestContext.self)
        router.post("/stream") { request, context -> Response in
            _ = try await request.body.collect(upTo: 1024)
            probe.recordBodyWrite()
            return try await BridgeDevelopmentHTTPProductResponse.make(
                from: results, onConnectionClose: context.onConnectionClose)
        }
        let application = Application(responder: router.buildResponder())
        try await application.test(.live) { serverClient in
            let port = try #require(serverClient.port)
            try await TestClient.withClient(host: "localhost", port: port) { client in
                try await client.executeAndDontWaitForResponse(
                    .init("/stream", method: .post, body: ByteBuffer(string: "request")))
                await probe.waitForBodyWrite()

                // Act — force a reset, not a FIN that also represents a valid request half-close.
                let socket = try #require(try await client.getChannel() as? any SocketOptionProvider)
                try await socket.setSoLinger(linger(l_onoff: 1, l_linger: 0)).get()
                try await client.close(mode: .all)

                // Assert
                await probe.waitForCancellation()
                continuation.finish()
            }
        }
    }

    @Test("request half-close does not discard a pending finite response")
    func requestHalfClosePreservesPendingResponse() async throws {
        // Arrange — a client can finish sending and still wait for its response.
        let probe = HTTPResponseCancellationProbe()
        let responseURL = try #require(URL(string: "http://localhost/finite"))
        let (results, continuation) = AsyncThrowingStream<URLSchemeTaskResult, any Error>.makeStream()
        defer { continuation.finish() }
        let router = Router(context: BridgeDevelopmentHTTPRequestContext.self)
        router.post("/finite") { request, context -> Response in
            _ = try await request.body.collect(upTo: 1024)
            probe.recordBodyWrite()
            return try await BridgeDevelopmentHTTPProductResponse.make(
                from: results, onConnectionClose: context.onConnectionClose)
        }
        let application = Application(responder: router.buildResponder())
        try await application.test(.live) { serverClient in
            let port = try #require(serverClient.port)
            try await TestClient.withClient(host: "localhost", port: port) { client in
                async let pendingResponse = client.execute(
                    .init("/finite", method: .post, body: ByteBuffer(string: "request")))
                await probe.waitForBodyWrite()

                // Act — keep the receive side open, then make the delayed response available.
                try await client.close(mode: .output)
                let responseHead = try #require(
                    HTTPURLResponse(
                        url: responseURL, statusCode: 202, httpVersion: "HTTP/1.1",
                        headerFields: ["Content-Type": "application/json"]))
                continuation.yield(.response(responseHead))
                continuation.yield(.data(Data("complete".utf8)))
                continuation.finish()

                // Assert
                let response = try await pendingResponse
                #expect(response.head.status.code == 202)
                #expect(response.body.map { String(buffer: $0) } == "complete")
            }
        }
    }

    @Test("finite upstream responses preserve status, headers, bytes and keep-alive", arguments: [200, 403, 409])
    func finiteResponsesPreserveHTTPContract(statusCode: Int) async throws {
        // Arrange — exercise the same response/context adapter twice on one client socket.
        let probe = HTTPResponseCancellationProbe()
        let responseURL = try #require(URL(string: "http://localhost/finite"))
        let router = Router(context: BridgeDevelopmentHTTPRequestContext.self)
        router.post("/finite") { request, context -> Response in
            let requestBytes = try await request.body.collect(upTo: 1024)
            context.onConnectionClose { probe.recordCancellation() }
            let upstreamResponse = try #require(
                HTTPURLResponse(
                    url: responseURL, statusCode: statusCode, httpVersion: "HTTP/1.1",
                    headerFields: [
                        "Content-Type": "application/json", "Access-Control-Allow-Origin": "http://localhost",
                    ]))
            let (results, continuation) = AsyncThrowingStream<URLSchemeTaskResult, any Error>.makeStream()
            continuation.yield(.response(upstreamResponse))
            continuation.yield(.data(Data(requestBytes.readableBytesView)))
            continuation.finish()
            return try await BridgeDevelopmentHTTPProductResponse.make(
                from: results, onConnectionClose: context.onConnectionClose)
        }
        let application = Application(responder: router.buildResponder())

        // Act / Assert — TestClient reuses its connection; a helper that closes it fails here.
        try await application.test(.live) { client in
            for body in ["first", "second"] {
                try await client.execute(uri: "/finite", method: .post, body: ByteBuffer(string: body)) { response in
                    #expect(response.status.code == statusCode)
                    #expect(response.headers[.contentType] == "application/json")
                    #expect(response.headers[.accessControlAllowOrigin] == "http://localhost")
                    #expect(String(buffer: response.body) == body)
                    #expect(!probe.isCancelled)
                }
            }
        }
    }

    @Test("production connection lifetime forwards idle disconnect after consuming the POST once")
    func consumedPostBodyAllowsIdleDisconnectCancellation() async throws {
        // Arrange — the real adapter consumes the POST once and observes the connection separately.
        let probe = HTTPResponseCancellationProbe()
        let (results, continuation) = try makeIdleSchemeResponse(probe: probe)
        defer { continuation.finish() }
        let router = Router(context: BridgeDevelopmentHTTPRequestContext.self)
        router.post("/stream") { request, context -> Response in
            let requestBytes = try await request.body.collect(upTo: 1024)
            #expect(String(buffer: requestBytes) == "request")
            var response = try await BridgeDevelopmentHTTPProductResponse.make(
                from: results, onConnectionClose: context.onConnectionClose)
            response.body = response.body.map { buffer in
                probe.recordBodyWrite()
                return buffer
            }
            return response
        }
        let application = Application(responder: router.buildResponder())
        try await application.test(.live) { serverClient in
            let port = try #require(serverClient.port)
            try await TestClient.withClient(host: "localhost", port: port) { client in
                try await client.executeAndDontWaitForResponse(
                    .init("/stream", method: .post, body: ByteBuffer(string: "request"))
                )
                await probe.waitForBodyWrite()

                // Act — no additional native chunk may trigger a write failure.
                // A FIN is also a valid request half-close; inject an unambiguous abort.
                let socket = try #require(try await client.getChannel() as? any SocketOptionProvider)
                try await socket.setSoLinger(linger(l_onoff: 1, l_linger: 0)).get()
                try await client.close(mode: .all)

                // Assert — connection closure, not a heartbeat, supplies cancellation.
                await probe.waitForCancellation()
                continuation.finish()
            }
        }
    }

    @Test("a failed HTTP body writer cancels its upstream scheme stream")
    func failedWriterCancelsUpstream() async throws {
        // Arrange
        let probe = HTTPResponseCancellationProbe()
        let (results, continuation) = try makeIdleSchemeResponse(probe: probe)
        defer { continuation.finish() }
        let response = try await BridgeDevelopmentHTTPProductResponse.make(from: results)

        // Act
        await #expect(throws: HTTPResponseWriteFailure.self) {
            try await response.body.write(RejectingHTTPResponseWriter())
        }

        // Assert — retaining the Response must not retain an abandoned producer.
        await probe.waitForCancellation()
        continuation.finish()
    }

}

private func makeIdleSchemeResponse(
    probe: HTTPResponseCancellationProbe
) throws -> (
    AsyncThrowingStream<URLSchemeTaskResult, any Error>,
    AsyncThrowingStream<URLSchemeTaskResult, any Error>.Continuation
) {
    let (results, continuation) = AsyncThrowingStream<URLSchemeTaskResult, any Error>.makeStream()
    continuation.onTermination = { termination in
        if case .cancelled = termination { probe.recordCancellation() }
    }
    let responseURL = try #require(URL(string: "http://localhost/stream"))
    let response = try #require(
        HTTPURLResponse(
            url: responseURL,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/octet-stream"]
        ))
    continuation.yield(.response(response))
    continuation.yield(.data(Data([1])))
    return (results, continuation)
}

private enum HTTPResponseWriteFailure: Error {
    case disconnected
}

private struct RejectingHTTPResponseWriter: ResponseBodyWriter {
    func write(_: ByteBuffer) throws { throw HTTPResponseWriteFailure.disconnected }
    func finish(_: HTTPFields?) throws { throw HTTPResponseWriteFailure.disconnected }
}

/// Both facts arrive on owner callbacks — `continuation.onTermination`,
/// `context.onConnectionClose`, and the response body-map closures — so the latch lets
/// those callbacks release waiters instead of flipping a flag for a loop to find.
private final class HTTPResponseCancellationProbe: Sendable {
    private let cancellationSignal = BridgeDevelopmentHTTPLifetimeSignal()
    private let bodyWriteSignal = BridgeDevelopmentHTTPLifetimeSignal()

    func recordCancellation() { cancellationSignal.signal() }
    var isCancelled: Bool { cancellationSignal.isSignalled }
    func recordBodyWrite() { bodyWriteSignal.signal() }

    func waitForCancellation() async { await cancellationSignal.wait() }
    func waitForBodyWrite() async { await bodyWriteSignal.wait() }
}
