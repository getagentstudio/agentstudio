import AgentStudioBridge
import Foundation

/// Development-server substitute for App-owned clipboard and save-panel effects.
///
/// The Vite loop must exercise the real output coordinator and durable history,
/// but a headless HTTP development host must never claim system clipboard or
/// save-panel authority. This effect captures exact bytes beneath the isolated
/// development data root so runtime proof can inspect them directly.
package actor BridgeDevelopmentWorktreeAnnotationOutputEffect:
    WorktreeAnnotationOutputEffect
{
    package nonisolated let outputDirectory: URL

    private var reservedJSONDestinationPaths: Set<String> = []

    package init(dataRoot: URL) {
        outputDirectory =
            dataRoot
            .appending(path: "annotation-output-captures", directoryHint: .isDirectory)
            .standardizedFileURL
    }

    package func rememberedJSONFolder() async -> String {
        outputDirectory.path
    }

    package func chooseJSONDestination(productAdmission: BridgeProductAdmissionContext) async
        -> WorktreeAnnotationOutputDestinationOutcome
    {
        guard productAdmission.withValidAdmission({ !Task.isCancelled }) == true else { return .cancelled }
        do {
            try FileManager.default.createDirectory(
                at: outputDirectory,
                withIntermediateDirectories: true
            )
            return productAdmission.withValidAdmission { .selected(path: outputDirectory.path) } ?? .cancelled
        } catch {
            return .failed(
                "The isolated development output directory could not be prepared: "
                    + error.localizedDescription
            )
        }
    }

    package func revealJSONFile(path: String, productAdmission: BridgeProductAdmissionContext) async -> Bool {
        // Headless development does not claim Finder authority.
        _ = path
        guard productAdmission.withValidAdmission({ true }) == true else { return false }
        return false
    }

    package func perform(
        _ request: WorktreeAnnotationOutputEffectRequest
    ) async -> WorktreeAnnotationOutputEffectOutcome {
        guard request.productAdmission.withValidAdmission({ !Task.isCancelled }) == true else { return .cancelled }
        let destination: URL
        switch request.outputKind {
        case .clipboardMarkdown:
            destination = clipboardCaptureURL(for: request.attemptID)
        case .jsonFile:
            guard let destinationPath = request.destinationPath else {
                return .failed(
                    "The JSON destination was outside the isolated development output directory."
                )
            }
            let requestedURL = URL(fileURLWithPath: destinationPath).standardizedFileURL
            guard requestedURL.deletingLastPathComponent() == outputDirectory else {
                return .failed(
                    "The JSON destination was outside the isolated development output directory."
                )
            }
            if let filename = request.suggestedFilename {
                guard isSafeSuggestedFilename(filename) else {
                    return .failed("The development JSON export filename was invalid.")
                }
                destination = nextAvailableJSONDestination(suggestedFilename: filename)
                reservedJSONDestinationPaths.insert(destination.path)
            } else {
                destination = requestedURL
            }
        }

        do {
            try FileManager.default.createDirectory(
                at: outputDirectory,
                withIntermediateDirectories: true
            )
            try request.exactBytes.write(to: destination, options: .atomic)
            return .succeeded(destinationPath: request.outputKind == .jsonFile ? destination.path : nil)
        } catch {
            return .failed(
                "The development output capture could not be written: \(error.localizedDescription)"
            )
        }
    }

    package nonisolated func clipboardCaptureURL(for attemptID: UUID) -> URL {
        outputDirectory.appending(
            path: "clipboard-\(attemptID.uuidString.lowercased()).md",
            directoryHint: .notDirectory
        )
    }

    private func nextAvailableJSONDestination(suggestedFilename: String) -> URL {
        let suggestedURL = URL(fileURLWithPath: suggestedFilename)
        let stem = suggestedURL.deletingPathExtension().lastPathComponent
        let pathExtension = suggestedURL.pathExtension
        var sequence = 1
        while true {
            let filename =
                sequence == 1
                ? suggestedFilename
                : "\(stem)-\(sequence).\(pathExtension)"
            let candidate = outputDirectory.appending(
                path: filename,
                directoryHint: .notDirectory
            )
            if !reservedJSONDestinationPaths.contains(candidate.path),
                !FileManager.default.fileExists(atPath: candidate.path)
            {
                return candidate
            }
            sequence += 1
        }
    }

    private func isSafeSuggestedFilename(_ filename: String) -> Bool {
        !filename.isEmpty
            && filename == URL(fileURLWithPath: filename).lastPathComponent
            && URL(fileURLWithPath: filename).pathExtension.lowercased() == "json"
    }

}
