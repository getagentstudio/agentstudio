import Foundation

enum BridgeProductSchemeRoute: Equatable, Sendable {
    case command
    case content
    case metadataStream

    fileprivate var absoluteURL: String {
        switch self {
        case .command: BridgeProductWireContract.commandRoute
        case .content: BridgeProductWireContract.contentRoute
        case .metadataStream: BridgeProductWireContract.streamRoute
        }
    }

    var diagnosticName: String {
        switch self {
        case .command: "command"
        case .content: "content"
        case .metadataStream: "metadata_stream"
        }
    }

    static func classify(_ url: URL) -> Self? {
        [.command, .metadataStream, .content].first { route in
            url.absoluteString == route.absoluteURL
        }
    }
}

struct BridgeProductSchemeAcceptedRequest: Equatable, Sendable {
    let bodySource: BridgeProductRequestBodySource
    let exactBodyBytes: Data
    let presentedCapability: String
    let route: BridgeProductSchemeRoute
    let url: URL
}

struct BridgeProductSchemeRequestRejection: Equatable, Sendable {
    let bodySource: BridgeProductRequestBodySource
    let observedBodyByteCount: Int
    let statusCode: Int
    let url: URL?
}

enum BridgeProductSchemeRequestAdmissionResult: Equatable, Sendable {
    case accepted(BridgeProductSchemeAcceptedRequest)
    case preflight(route: BridgeProductSchemeRoute, url: URL)
    case rejected(BridgeProductSchemeRequestRejection)
}

struct BridgeProductSchemeRequestAdmission: Sendable {
    let session: BridgeProductSession
    let bodyReader: BridgeProductBoundedRequestBodyReader
    let productAdmission: BridgeProductAdmissionContext

    init(
        session: BridgeProductSession,
        productAdmission: BridgeProductAdmissionContext,
        maximumRequestBodyBytes: Int = BridgeProductWireContract.maximumRequestBodyBytes
    ) {
        self.session = session
        self.productAdmission = productAdmission
        self.bodyReader = BridgeProductBoundedRequestBodyReader(
            maximumBytes: maximumRequestBodyBytes
        )
    }

    func admit(_ request: URLRequest) async -> BridgeProductSchemeRequestAdmissionResult {
        guard let url = request.url,
            let route = BridgeProductSchemeRoute.classify(url)
        else {
            return rejected(statusCode: 404, url: request.url)
        }
        if request.httpMethod == "OPTIONS" {
            return .preflight(route: route, url: url)
        }
        guard request.httpMethod == BridgeProductWireContract.requestMethod else {
            return rejected(statusCode: 405, url: url)
        }
        guard
            let presentedCapability = request.value(
                forHTTPHeaderField: BridgeProductWireContract.capabilityHeaderName
            )
        else {
            return rejected(statusCode: 401, url: url)
        }
        let isAuthorized: Bool
        if route == .command {
            isAuthorized = await session.authenticatesControlCapability(presentedCapability)
        } else {
            isAuthorized = await session.authorizes(presentedCapability: presentedCapability)
        }
        guard isAuthorized else {
            return rejected(statusCode: 403, url: url)
        }
        guard
            (productAdmission.withValidAdmission { true }) == true
        else {
            return rejected(statusCode: 409, url: url)
        }
        guard Self.hasJSONContentType(request) else {
            return rejected(statusCode: 415, url: url)
        }

        switch bodyReader.read(request) {
        case .missing:
            return rejected(
                statusCode: 400,
                url: url,
                bodySource: .missing
            )
        case .invalid(let source, let observedByteCount):
            return rejected(
                statusCode: 400,
                url: url,
                bodySource: source,
                observedBodyByteCount: observedByteCount
            )
        case .oversized(let source, let observedByteCount):
            return rejected(
                statusCode: 413,
                url: url,
                bodySource: source,
                observedBodyByteCount: observedByteCount
            )
        case .body(let body, let source):
            return .accepted(
                .init(
                    bodySource: source,
                    exactBodyBytes: body,
                    presentedCapability: presentedCapability,
                    route: route,
                    url: url
                )
            )
        }
    }

    private static func hasJSONContentType(_ request: URLRequest) -> Bool {
        guard let rawValue = request.value(forHTTPHeaderField: "Content-Type") else {
            return false
        }
        let components = rawValue.split(
            separator: ";",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard
            components[0].trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() == "application/json"
        else {
            return false
        }
        guard components.count == 2 else { return true }
        return components[1].trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "charset=utf-8"
    }

    private func rejected(
        statusCode: Int,
        url: URL?,
        bodySource: BridgeProductRequestBodySource = .unread,
        observedBodyByteCount: Int = 0
    ) -> BridgeProductSchemeRequestAdmissionResult {
        .rejected(
            .init(
                bodySource: bodySource,
                observedBodyByteCount: observedBodyByteCount,
                statusCode: statusCode,
                url: url
            )
        )
    }
}
