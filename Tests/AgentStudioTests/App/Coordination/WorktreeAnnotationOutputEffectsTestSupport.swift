import AgentStudioInfrastructure
import AgentStudioTestHarness
import AppKit
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioBridge
@testable import AgentStudioCore
@testable import AgentStudioTestSupport

@MainActor
final class RejectingAnnotationPasteboard: WorktreeAnnotationPasteboardWriting {
    private(set) var didClearContents = false

    func clearContents() -> Int {
        didClearContents = true
        return 1
    }

    func setData(_ data: Data?, forType dataType: NSPasteboard.PasteboardType) -> Bool {
        _ = (data, dataType)
        return false
    }
}

@MainActor
final class TestJSONFolderPanel: WorktreeAnnotationJSONFolderPanel {
    var canChooseDirectories = false
    var canChooseFiles = true
    var allowsMultipleSelection = true
    private(set) var didBegin = false
    let url: URL?

    private let response: NSApplication.ModalResponse
    init(
        response: NSApplication.ModalResponse,
        selectedURL: URL?
    ) {
        self.response = response
        self.url = selectedURL
    }

    func begin(completionHandler: @escaping (NSApplication.ModalResponse) -> Void) {
        didBegin = true
        completionHandler(response)
    }

    func cancel(_ sender: Any?) {
        _ = sender
    }
}

@MainActor
final class HoldingJSONFolderPanel: WorktreeAnnotationJSONFolderPanel {
    var canChooseDirectories = false
    var canChooseFiles = true
    var allowsMultipleSelection = true
    let url: URL? = URL(filePath: "/tmp/late-selection", directoryHint: .isDirectory)
    let beginnings: AsyncStream<Void>
    private let beginningContinuation: AsyncStream<Void>.Continuation
    private var completionHandler: ((NSApplication.ModalResponse) -> Void)?
    private(set) var cancelCount = 0

    init() {
        let stream = AsyncStream.makeStream(of: Void.self)
        beginnings = stream.stream
        beginningContinuation = stream.continuation
    }

    func begin(completionHandler: @escaping (NSApplication.ModalResponse) -> Void) {
        self.completionHandler = completionHandler
        beginningContinuation.yield(())
    }

    func cancel(_ sender: Any?) {
        _ = sender
        cancelCount += 1
        completionHandler?(.cancel)
    }

    func complete(_ response: NSApplication.ModalResponse) {
        completionHandler?(response)
    }
}

actor RecordingFailingJSONWriter {
    private(set) var writeCount = 0

    func write(_ data: Data, to destination: URL) throws {
        _ = (data, destination)
        writeCount += 1
        throw TestOutputEffectFailure.forced
    }
}

actor RecordingJSONWriter {
    private(set) var writeCount = 0

    func record(data: Data, destination: URL, filename: String?) -> URL {
        _ = (data, filename)
        writeCount += 1
        return destination
    }
}

enum TestOutputEffectFailure: Error {
    case forced
}

@MainActor func freshOutputAdmission() -> BridgeProductAdmissionContext {
    guard let admission = BridgeProductAdmissionGate().acquire() else {
        preconditionFailure("Fresh test gate must be open")
    }
    return admission
}

@MainActor func outputInstallationHarness() async throws -> (
    owner: BridgePaneProductSessionOwner, claim: BridgeProductSchemeTransportClaim
) {
    let owner = try BridgePaneProductSessionOwner(
        paneSessionId: UUIDv7.generate().uuidString,
        provider: BridgePaneProductSessionProviderGate(), productAdmissionGate: BridgeProductAdmissionGate(),
        retirementClock: TestPushClock()
    )
    let pane = try #require(owner.productAdmissionGate.acquire())
    let installation = try await owner.prepareCandidate(productAdmission: pane)
    #expect(await owner.activatePreparedCandidate(installation, productAdmission: pane) == .activated)
    guard
        case .admitted(let claim) = await owner.schemeRouter.claimActiveAdapter(
            presentedCapability: try BridgeProductCapabilityHeaderEncoding.encode(installation.capabilityBytes),
            schemeTaskId: UUIDv7.generate(), route: .command)
    else { throw TestOutputEffectFailure.forced }
    return (owner, claim)
}
