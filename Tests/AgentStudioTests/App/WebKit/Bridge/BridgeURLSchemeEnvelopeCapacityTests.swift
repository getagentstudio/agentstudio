import Foundation
import Testing
import WebKit

@testable import AgentStudio
@testable import AgentStudioInfrastructure
@testable import AgentStudioTestSupport
@testable import AgentStudioWebview

extension WebKitSerializedTests {
    @MainActor
    @Suite(.serialized)
    struct BridgeURLSchemeEnvelopeCapacityTests {
        @Test(
            "real URL scheme preserves response and POST bytes across the suspected 256 KiB boundary",
            arguments: [256 * 1024 - 1, 256 * 1024 + 1, 1024 * 1024], [false, true]
        )
        func roundTripPreservesBytes(byteCount: Int, chunked: Bool) async throws {
            // Arrange — real WebKit carrier, intentionally without product size policy.
            installTestCoreAtomsIfNeeded()
            var configuration = WebPageTestHarness.makeConfiguration()
            let scheme = try #require(URLScheme("agentstudio"))
            configuration.urlSchemeHandlers[scheme] = EnvelopeCapacitySchemeHandler(
                byteCount: byteCount, chunked: chunked)
            let page = WebPage(
                configuration: configuration,
                navigationDecider: WebviewNavigationDecider(),
                dialogPresenter: WebviewDialogHandler())

            try await WebPageTestHarness.withManagedPage(page) { page in
                // Act — the page GETs a payload, POSTs it back, and verifies the echo.
                _ = page.load(URL(string: "agentstudio://capacity/index.html"))
                let terminalTitle = await WebPageEventWaits.waitForTitle(page, beginningWith: "capacity:")

                // Assert — exact bytes, not only successful request completion or length.
                #expect(terminalTitle == "capacity:passed:\(byteCount)")
                print("URL scheme capacity bytes=\(byteCount) chunked=\(chunked) terminal=\(terminalTitle)")
            }
        }
    }
}

private struct EnvelopeCapacitySchemeHandler: URLSchemeHandler {
    let byteCount: Int
    let chunked: Bool

    func reply(for request: URLRequest) -> some AsyncSequence<URLSchemeTaskResult, any Error> {
        AsyncThrowingStream<URLSchemeTaskResult, any Error> { continuation in
            do {
                let url = try requireURL(request)
                let data: Data
                let mimeType: String
                switch url.path {
                case "/index.html":
                    data = Data(pageHTML.utf8)
                    mimeType = "text/html"
                case "/payload":
                    data = Data((0..<byteCount).map { UInt8($0 % 251) })
                    mimeType = "application/octet-stream"
                case "/echo":
                    data = try requestBody(request)
                    guard data.count == byteCount else { throw CapacityProbeError.unexpectedBodyLength }
                    mimeType = "application/octet-stream"
                default:
                    throw CapacityProbeError.unexpectedRoute
                }
                continuation.yield(
                    .response(
                        URLResponse(
                            url: url, mimeType: mimeType, expectedContentLength: data.count,
                            textEncodingName: mimeType == "text/html" ? "utf-8" : nil)))
                let deliveryBytes = chunked ? 64 * 1024 : data.count
                for offset in stride(from: 0, to: data.count, by: deliveryBytes) {
                    continuation.yield(.data(data.subdata(in: offset..<min(offset + deliveryBytes, data.count))))
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    private func requireURL(_ request: URLRequest) throws -> URL {
        guard let url = request.url else { throw CapacityProbeError.unexpectedRoute }
        return url
    }

    private func requestBody(_ request: URLRequest) throws -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { throw CapacityProbeError.missingBody }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { throw CapacityProbeError.bodyReadFailed }
            if count == 0 { return data }
            guard data.count + count <= byteCount else { throw CapacityProbeError.unexpectedBodyLength }
            data.append(contentsOf: buffer.prefix(count))
        }
    }

    private var pageHTML: String {
        """
        <!doctype html><html><head><title>Loading capacity probe</title></head><body><script>
        (async () => {
          const verify = (buffer) => {
            const bytes = new Uint8Array(buffer);
            if (bytes.length !== \(byteCount)) throw new Error('length');
            for (let index = 0; index < bytes.length; index++) {
              if (bytes[index] !== index % 251) throw new Error('bytes');
            }
          };
          try {
            const response = await fetch('agentstudio://capacity/payload');
            const buffer = await response.arrayBuffer();
            verify(buffer);
            const echo = await fetch('agentstudio://capacity/echo', { method: 'POST', body: buffer });
            verify(await echo.arrayBuffer());
            document.title = 'capacity:passed:\(byteCount)';
          } catch (error) {
            document.title = 'capacity:failed:' + String(error);
          }
        })();
        </script></body></html>
        """
    }
}

private enum CapacityProbeError: Error {
    case unexpectedRoute
    case missingBody
    case bodyReadFailed
    case unexpectedBodyLength
}
