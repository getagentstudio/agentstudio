import AgentStudioBridge
import AppKit
import Darwin
import Foundation

@MainActor
protocol WorktreeAnnotationPasteboardWriting: AnyObject {
    @discardableResult
    func clearContents() -> Int
    @discardableResult
    func setData(_ data: Data?, forType dataType: NSPasteboard.PasteboardType) -> Bool
}

extension NSPasteboard: WorktreeAnnotationPasteboardWriting {}

@MainActor
protocol WorktreeAnnotationJSONFolderPanel: AnyObject {
    var canChooseDirectories: Bool { get set }
    var canChooseFiles: Bool { get set }
    var allowsMultipleSelection: Bool { get set }
    var url: URL? { get }
    func begin(completionHandler: @escaping (NSApplication.ModalResponse) -> Void)
    func cancel(_ sender: Any?)
}

extension NSOpenPanel: WorktreeAnnotationJSONFolderPanel {}

@MainActor
protocol WorktreeAnnotationOutputFolderPreference: AnyObject {
    var folderURL: URL { get set }
}

/// Interim application-lifetime preference until the owner decides its persistence boundary.
@MainActor
final class InMemoryWorktreeAnnotationOutputFolderPreference: WorktreeAnnotationOutputFolderPreference {
    var folderURL: URL

    init(folderURL: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]) {
        self.folderURL = folderURL
    }
}

/// App-owned clipboard, folder selection, and file writer for Bridge output.
@MainActor
final class WorktreeAnnotationOutputEffects: WorktreeAnnotationOutputEffect {
    typealias FolderPanelFactory = @MainActor () throws -> any WorktreeAnnotationJSONFolderPanel
    typealias JSONDataWriter = @Sendable (Data, URL, String?) async throws -> URL

    private let pasteboard: any WorktreeAnnotationPasteboardWriting
    private let makeFolderPanel: FolderPanelFactory
    private let folderPreference: any WorktreeAnnotationOutputFolderPreference
    private let writeJSONData: JSONDataWriter
    private let didAdmitJSONWrite: @Sendable () -> Void

    init(
        pasteboard: any WorktreeAnnotationPasteboardWriting = NSPasteboard.general,
        makeFolderPanel: @escaping FolderPanelFactory = { NSOpenPanel() },
        folderPreference: any WorktreeAnnotationOutputFolderPreference =
            InMemoryWorktreeAnnotationOutputFolderPreference(),
        writeJSONData: @escaping JSONDataWriter = WorktreeAnnotationOutputEffects.writeJSONData,
        didAdmitJSONWrite: @escaping @Sendable () -> Void = {}
    ) {
        self.pasteboard = pasteboard
        self.makeFolderPanel = makeFolderPanel
        self.folderPreference = folderPreference
        self.writeJSONData = writeJSONData
        self.didAdmitJSONWrite = didAdmitJSONWrite
    }

    func rememberedJSONFolder() -> String {
        folderPreference.folderURL.path
    }

    func revealJSONFile(path: String, productAdmission: BridgeProductAdmissionContext) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return false }
        return productAdmission.withValidAdmission {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            return true
        } ?? false
    }

    func chooseJSONDestination(productAdmission: BridgeProductAdmissionContext) async
        -> WorktreeAnnotationOutputDestinationOutcome
    {
        do {
            let panel = try makeFolderPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            let panelWait = WorktreeAnnotationFolderPanelWait(
                panel: panel, preference: folderPreference, productAdmission: productAdmission)
            panelWait.observeClose()
            let outcome = await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in panelWait.install(continuation) }
            } onCancel: {
                panelWait.latchCancellation()
            }
            return outcome
        } catch {
            return .failed("The JSON export folder could not be selected: \(error.localizedDescription)")
        }
    }

    func perform(
        _ request: WorktreeAnnotationOutputEffectRequest
    ) async -> WorktreeAnnotationOutputEffectOutcome {
        switch request.outputKind {
        case .clipboardMarkdown:
            return request.productAdmission.withValidAdmission {
                guard !Task.isCancelled else { return WorktreeAnnotationOutputEffectOutcome.cancelled }
                pasteboard.clearContents()
                guard pasteboard.setData(request.exactBytes, forType: .string) else {
                    return .failed("The system pasteboard did not confirm the Markdown write.")
                }
                return .succeeded(destinationPath: nil)
            } ?? .cancelled
        case .jsonFile:
            guard let destinationPath = request.destinationPath, !destinationPath.isEmpty else {
                return .failed("The prepared JSON output has no destination.")
            }
            // Logical write admission competes atomically with both fences; I/O is App-owned afterward.
            guard request.productAdmission.withValidAdmission({ !Task.isCancelled }) == true else { return .cancelled }
            didAdmitJSONWrite()
            let writer = writeJSONData
            let exactBytes = request.exactBytes
            let filename = request.suggestedFilename
            let destinationURL = URL(fileURLWithPath: destinationPath)
            // swiftlint:disable:next no_task_detached
            let applicationWrite = Task.detached(priority: .userInitiated) {
                try await writer(exactBytes, destinationURL, filename)
            }
            do {
                let writtenURL = try await applicationWrite.value
                return .succeeded(destinationPath: writtenURL.path)
            } catch let error as WorktreeAnnotationJSONWriteError {
                switch error {
                case .missingFolder:
                    return .fileFailure(code: .missingFolder, message: error.localizedDescription)
                case .permissionDenied:
                    return .fileFailure(code: .permissionDenied, message: error.localizedDescription)
                case .tooManyCollisions:
                    return .failed(error.localizedDescription)
                }
            } catch {
                return .failed("The JSON export could not be written: \(error.localizedDescription)")
            }
        }
    }

    @concurrent nonisolated private static func writeJSONData(
        _ data: Data,
        _ destination: URL,
        _ suggestedFilename: String?
    ) async throws -> URL {
        guard let suggestedFilename else {
            try data.write(to: destination, options: .atomic)
            return destination
        }
        let folder = destination.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw WorktreeAnnotationJSONWriteError.missingFolder
        }
        let stem = URL(fileURLWithPath: suggestedFilename).deletingPathExtension().lastPathComponent
        for collisionIndex in 0..<1000 {
            let filename =
                collisionIndex == 0
                ? suggestedFilename
                : "\(stem)-\(collisionIndex + 1).json"
            let candidate = folder.appendingPathComponent(filename)
            let descriptor = Darwin.open(candidate.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            if descriptor < 0 {
                if errno == EEXIST { continue }
                if errno == ENOENT { throw WorktreeAnnotationJSONWriteError.missingFolder }
                if errno == EACCES || errno == EPERM || errno == EROFS {
                    throw WorktreeAnnotationJSONWriteError.permissionDenied
                }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            var descriptorOpen = true
            do {
                try data.withUnsafeBytes { bytes in
                    guard let base = bytes.baseAddress else { return }
                    var written = 0
                    while written < bytes.count {
                        let count = Darwin.write(descriptor, base.advanced(by: written), bytes.count - written)
                        if count < 0 && errno == EINTR { continue }
                        if count <= 0 {
                            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                        }
                        written += count
                    }
                }
                let closeResult = Darwin.close(descriptor)
                descriptorOpen = false
                guard closeResult == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                return candidate
            } catch {
                if descriptorOpen { _ = Darwin.close(descriptor) }
                _ = Darwin.unlink(candidate.path)
                throw error
            }
        }
        throw WorktreeAnnotationJSONWriteError.tooManyCollisions
    }
}

private enum WorktreeAnnotationJSONWriteError: LocalizedError {
    case missingFolder
    case permissionDenied
    case tooManyCollisions

    var errorDescription: String? {
        switch self {
        case .missingFolder: "The export folder no longer exists. Choose a folder and try again."
        case .permissionDenied: "Permission to write in the export folder was denied. Choose a folder and try again."
        case .tooManyCollisions: "The export folder contains too many files with this name."
        }
    }
}
