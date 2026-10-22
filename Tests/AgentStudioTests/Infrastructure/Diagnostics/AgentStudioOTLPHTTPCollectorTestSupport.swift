import Foundation
import Network

struct LoopbackOTLPHTTPRequest: Equatable, Sendable {
    let method: String
    let path: String
    let headers: [String: String]
    let bodyByteCount: Int
    let body: Data

    func bodyContains(_ value: String) -> Bool {
        let needle = Array(value.utf8)
        guard !needle.isEmpty else { return true }
        return body.indices.contains { index in
            body[index...].starts(with: needle)
        }
    }

    func bodyContains(hexEncodedBytes value: String) -> Bool {
        guard let needle = Data(hexEncoded: value), !needle.isEmpty else { return false }
        return body.indices.contains { index in
            body[index...].starts(with: needle)
        }
    }
}

final class LoopbackOTLPHTTPCollector: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "agentstudio.tests.otlp-collector")
    private let requestLock = NSLock()
    private var recordedRequests: [LoopbackOTLPHTTPRequest] = []
    private let requestStream: AsyncStream<LoopbackOTLPHTTPRequest>
    private let requestContinuation: AsyncStream<LoopbackOTLPHTTPRequest>.Continuation
    private let readyStream: AsyncStream<Void>
    private let readyContinuation: AsyncStream<Void>.Continuation

    init() throws {
        self.listener = try NWListener(using: .tcp, on: .any)

        var requestContinuation: AsyncStream<LoopbackOTLPHTTPRequest>.Continuation!
        self.requestStream = AsyncStream { continuation in
            requestContinuation = continuation
        }
        self.requestContinuation = requestContinuation

        var readyContinuation: AsyncStream<Void>.Continuation!
        self.readyStream = AsyncStream { continuation in
            readyContinuation = continuation
        }
        self.readyContinuation = readyContinuation
    }

    func endpoint() throws -> URL {
        guard let port = listener.port?.rawValue else {
            throw LoopbackOTLPHTTPCollectorError.missingPort
        }
        return URL(string: "http://127.0.0.1:\(port)")!
    }

    func start() async throws {
        listener.stateUpdateHandler = { [readyContinuation] state in
            switch state {
            case .ready:
                readyContinuation.yield(())
            case .failed:
                readyContinuation.finish()
            case .setup, .waiting, .cancelled:
                break
            @unknown default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: queue)

        guard await waitForReady() else {
            throw LoopbackOTLPHTTPCollectorError.notReady
        }
    }

    func cancel() {
        listener.cancel()
        requestContinuation.finish()
        readyContinuation.finish()
    }

    // Call after the producing runtime shuts down and cancel() closes this stream.
    // Missing exports then return an empty collection, rather than waiting for success.
    func receivedRequests() async -> [LoopbackOTLPHTTPRequest] {
        var requests: [LoopbackOTLPHTTPRequest] = []
        for await request in requestStream { requests.append(request) }
        return requests
    }

    func waitForRequest(containing value: String) async -> LoopbackOTLPHTTPRequest? {
        if let request = firstRecordedRequest(containing: value) {
            return request
        }

        for await request in requestStream {
            if request.bodyContains(value) {
                return request
            }
        }
        return nil
    }

    func waitForRequest(
        pathSuffix: String,
        containing value: String
    ) async -> LoopbackOTLPHTTPRequest? {
        if let request = firstRecordedRequest(pathSuffix: pathSuffix, containing: value) {
            return request
        }

        for await request in requestStream {
            if request.path.hasSuffix(pathSuffix), request.bodyContains(value) {
                return request
            }
        }
        return nil
    }

    private func waitForReady() async -> Bool {
        for await _ in readyStream {
            return true
        }
        return false
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 65_536,
            completion: receiveHandler(on: connection, buffer: buffer)
        )
    }

    private func receiveHandler(
        on connection: NWConnection,
        buffer: Data
    ) -> @Sendable (Data?, NWConnection.ContentContext?, Bool, NWError?) -> Void {
        { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }

            var nextBuffer = buffer
            if let data, !data.isEmpty {
                nextBuffer.append(data)
            }

            if let request = Self.parseRequest(nextBuffer) {
                self.record(request)
                self.sendOK(on: connection)
                return
            }

            if isComplete || error != nil {
                connection.cancel()
                return
            }

            self.receive(on: connection, buffer: nextBuffer)
        }
    }

    private func sendOK(on connection: NWConnection) {
        let response = Data("HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
        connection.send(
            content: response,
            completion: .contentProcessed { _ in
                connection.cancel()
            })
    }

    private func record(_ request: LoopbackOTLPHTTPRequest) {
        requestLock.lock()
        recordedRequests.append(request)
        requestLock.unlock()
        requestContinuation.yield(request)
    }

    private func firstRecordedRequest(containing value: String) -> LoopbackOTLPHTTPRequest? {
        requestLock.lock()
        defer { requestLock.unlock() }
        return recordedRequests.first { $0.bodyContains(value) }
    }

    private func firstRecordedRequest(pathSuffix: String, containing value: String) -> LoopbackOTLPHTTPRequest? {
        requestLock.lock()
        defer { requestLock.unlock() }
        return recordedRequests.first { request in
            request.path.hasSuffix(pathSuffix) && request.bodyContains(value)
        }
    }

    private static func parseRequest(_ data: Data) -> LoopbackOTLPHTTPRequest? {
        let headerTerminator = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: headerTerminator) else { return nil }
        let headerData = data[..<headerRange.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let requestParts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard requestParts.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            headers[parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] =
                parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let expectedBodyLength = headers["content-length"].flatMap(Int.init) ?? 0
        let bodyData = data[headerRange.upperBound...]
        guard bodyData.count >= expectedBodyLength else { return nil }

        return LoopbackOTLPHTTPRequest(
            method: requestParts[0],
            path: requestParts[1],
            headers: headers,
            bodyByteCount: expectedBodyLength,
            body: Data(bodyData.prefix(expectedBodyLength))
        )
    }
}

private enum LoopbackOTLPHTTPCollectorError: Error {
    case missingPort
    case notReady
}

extension Data {
    fileprivate init?(hexEncoded value: String) {
        guard value.count.isMultiple(of: 2) else { return nil }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(value.count / 2)

        var currentIndex = value.startIndex
        while currentIndex < value.endIndex {
            let nextIndex = value.index(currentIndex, offsetBy: 2)
            guard let byte = UInt8(value[currentIndex..<nextIndex], radix: 16) else {
                return nil
            }
            bytes.append(byte)
            currentIndex = nextIndex
        }

        self.init(bytes)
    }
}
