import AgentStudioBridge
import AgentStudioInfrastructure
import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers

@testable import AgentStudio

@MainActor
@Suite(.serialized)
struct WorktreeAnnotationOutputEffectsTests {
    @Test("clipboard output replaces stale contents with exact UTF-8 Markdown bytes")
    func clipboardOutputReplacesStaleContentsWithExactMarkdownBytes() async throws {
        let pasteboard = NSPasteboard(
            name: .init("agentstudio.annotation-output.\(UUIDv7.generate().uuidString)")
        )
        let staleType = NSPasteboard.PasteboardType("com.agentstudio.tests.stale-annotation-output")
        pasteboard.clearContents()
        #expect(pasteboard.setString("stale", forType: staleType))
        let exactBytes = Data("# Review comments\n\nPreserve café behavior.\n".utf8)
        let effect = WorktreeAnnotationOutputEffects(pasteboard: pasteboard)

        let outcome = await effect.perform(
            outputRequest(kind: .clipboardMarkdown, exactBytes: exactBytes)
        )

        #expect(outcome == .succeeded)
        #expect(pasteboard.data(forType: .string) == exactBytes)
        #expect(pasteboard.string(forType: staleType) == nil)
    }

    @Test("clipboard output reports failure when the pasteboard does not prove the write")
    func clipboardOutputReportsUnprovenWrite() async {
        let pasteboard = RejectingAnnotationPasteboard()
        let effect = WorktreeAnnotationOutputEffects(pasteboard: pasteboard)

        let outcome = await effect.perform(
            outputRequest(
                kind: .clipboardMarkdown,
                exactBytes: Data("# Review comments\n".utf8)
            )
        )

        guard case .failed(let message) = outcome else {
            Issue.record("Expected a typed pasteboard failure")
            return
        }
        #expect(!message.isEmpty)
        #expect(pasteboard.didClearContents)
    }

    @Test("JSON destination configures a JSON save panel and returns its selected path")
    func jsonDestinationConfiguresSavePanel() async {
        let destination = URL(filePath: "/tmp/agentstudio-selected-review-comments.json")
        let panel = TestJSONDestinationPanel(response: .OK, selectedURL: destination)
        let effect = WorktreeAnnotationOutputEffects(
            pasteboard: RejectingAnnotationPasteboard(),
            makeSavePanel: { panel }
        )

        let outcome = await effect.chooseJSONDestination(
            suggestedFilename: "AgentStudio Review Comments.json"
        )

        #expect(outcome == .selected(path: destination.path))
        #expect(panel.allowedContentTypes == [.json])
        #expect(panel.nameFieldStringValue == "AgentStudio Review Comments.json")
        #expect(panel.canCreateDirectories)
        #expect(!panel.isExtensionHidden)
    }

    @Test("JSON destination cancellation is typed cancellation")
    func jsonDestinationCancellationIsTyped() async {
        let panel = TestJSONDestinationPanel(response: .cancel, selectedURL: nil)
        let effect = WorktreeAnnotationOutputEffects(
            pasteboard: RejectingAnnotationPasteboard(),
            makeSavePanel: { panel }
        )

        let outcome = await effect.chooseJSONDestination(suggestedFilename: "comments.json")

        #expect(outcome == .cancelled)
    }

    @Test("JSON destination panel errors are typed failures")
    func jsonDestinationPanelErrorIsTypedFailure() async {
        let panel = TestJSONDestinationPanel(
            response: .OK,
            selectedURL: nil,
            presentationError: TestOutputEffectFailure.forced
        )
        let effect = WorktreeAnnotationOutputEffects(
            pasteboard: RejectingAnnotationPasteboard(),
            makeSavePanel: { panel }
        )

        let outcome = await effect.chooseJSONDestination(suggestedFilename: "comments.json")

        guard case .failed(let message) = outcome else {
            Issue.record("Expected a typed save-panel failure")
            return
        }
        #expect(!message.isEmpty)
    }

    @Test("JSON output atomically replaces the file at the persisted selected path")
    func jsonOutputWritesExactBytesToPersistedPath() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory.appending(
            path: "agentstudio-annotation-output-\(UUIDv7.generate().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let destination = temporaryRoot.appending(path: "review-comments.json")
        try Data("stale".utf8).write(to: destination)
        let exactBytes = Data("{\"formatVersion\":1,\"comments\":[]}".utf8)
        let effect = WorktreeAnnotationOutputEffects(
            pasteboard: RejectingAnnotationPasteboard()
        )

        let outcome = await effect.perform(
            outputRequest(
                kind: .jsonFile,
                exactBytes: exactBytes,
                destinationPath: destination.path
            )
        )

        #expect(outcome == .succeeded)
        #expect(try Data(contentsOf: destination) == exactBytes)
    }

    @Test("JSON output fails without the persisted selected path")
    func jsonOutputRejectsMissingPersistedPath() async {
        let effect = WorktreeAnnotationOutputEffects(
            pasteboard: RejectingAnnotationPasteboard()
        )

        let outcome = await effect.perform(
            outputRequest(kind: .jsonFile, exactBytes: Data("{}".utf8))
        )

        guard case .failed(let message) = outcome else {
            Issue.record("Expected a typed missing-path failure")
            return
        }
        #expect(!message.isEmpty)
    }

    @Test("JSON output reports one known failure without retrying")
    func jsonOutputDoesNotRetryKnownWriteFailure() async {
        let writer = RecordingFailingJSONWriter()
        let effect = WorktreeAnnotationOutputEffects(
            pasteboard: RejectingAnnotationPasteboard(),
            writeJSONData: { data, destination in
                try await writer.write(data, to: destination)
            }
        )

        let outcome = await effect.perform(
            outputRequest(
                kind: .jsonFile,
                exactBytes: Data("{}".utf8),
                destinationPath: "/tmp/agentstudio-known-failure.json"
            )
        )

        guard case .failed(let message) = outcome else {
            Issue.record("Expected a typed file-write failure")
            return
        }
        #expect(!message.isEmpty)
        #expect(await writer.writeCount == 1)
    }

    private func outputRequest(
        kind: WorktreeAnnotationOutputEffectKind,
        exactBytes: Data,
        destinationPath: String? = nil
    ) -> WorktreeAnnotationOutputEffectRequest {
        .init(
            attemptID: UUIDv7.generate(),
            outputKind: kind,
            contentType: kind == .clipboardMarkdown
                ? "text/markdown; charset=utf-8"
                : "application/json; charset=utf-8",
            exactBytes: exactBytes,
            destinationPath: destinationPath
        )
    }
}

@MainActor
private final class RejectingAnnotationPasteboard: WorktreeAnnotationPasteboardWriting {
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
private final class TestJSONDestinationPanel: WorktreeAnnotationJSONDestinationPanel {
    var allowedContentTypes: [UTType] = []
    var nameFieldStringValue = ""
    var canCreateDirectories = false
    var isExtensionHidden = true
    let url: URL?

    private let response: NSApplication.ModalResponse
    private let presentationError: (any Error)?

    init(
        response: NSApplication.ModalResponse,
        selectedURL: URL?,
        presentationError: (any Error)? = nil
    ) {
        self.response = response
        self.url = selectedURL
        self.presentationError = presentationError
    }

    func runModal() throws -> NSApplication.ModalResponse {
        if let presentationError { throw presentationError }
        return response
    }
}

private actor RecordingFailingJSONWriter {
    private(set) var writeCount = 0

    func write(_ data: Data, to destination: URL) throws {
        _ = (data, destination)
        writeCount += 1
        throw TestOutputEffectFailure.forced
    }
}

private enum TestOutputEffectFailure: Error {
    case forced
}
