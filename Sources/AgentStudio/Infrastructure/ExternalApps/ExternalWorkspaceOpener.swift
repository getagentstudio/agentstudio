import AppKit
import Foundation
import os

package enum ExternalWorkspaceOpener {
    enum OpenRequest: Equatable, Sendable {
        case application(bundleIdentifier: String, targetPath: URL)
        case command(executableURL: URL, arguments: [String])
    }

    private static let logger = Logger(subsystem: "com.agentstudio", category: "ExternalWorkspaceOpener")

    @discardableResult
    @MainActor
    package static func openInEditor(
        id: EditorTargetId,
        path: URL,
        installedTargets: [ExternalEditorTarget]? = nil
    ) -> Bool {
        let installedTargets = installedTargets ?? ExternalEditorTarget.refreshInstalledTargets()
        guard let target = installedTargets.first(where: { $0.id == id }) else {
            return false
        }

        let openRequests = requests(for: target, path: path)
        Task { @MainActor in
            _ = await openAsync(requests: openRequests)
        }
        return true
    }

    @MainActor
    package static func openInEditorAwaiting(
        id: EditorTargetId, path: URL, installedTargets: [ExternalEditorTarget]? = nil
    ) async -> Bool {
        await openInEditorAwaiting(
            id: id, path: path,
            installedTargets: installedTargets ?? ExternalEditorTarget.refreshInstalledTargets(),
            runner: runAsync)
    }

    @MainActor
    static func openInEditorAwaiting(
        id: EditorTargetId, path: URL, installedTargets: [ExternalEditorTarget],
        runner: @escaping (OpenRequest) async -> Bool
    ) async -> Bool {
        guard let target = installedTargets.first(where: { $0.id == id }) else { return false }
        return await openAsync(requests: requests(for: target, path: path), runner: runner)
    }

    static func requests(for target: ExternalEditorTarget, path: URL) -> [OpenRequest] {
        var requests: [OpenRequest] = []

        if !target.bundleIdentifier.isEmpty {
            requests.append(.application(bundleIdentifier: target.bundleIdentifier, targetPath: path))
        }

        requests.append(
            contentsOf: target.cliFallbacks.map { fallback in
                .command(
                    executableURL: fallback.executableURL,
                    arguments: fallback.arguments + [path.path]
                )
            }
        )

        return requests
    }

    @discardableResult
    @MainActor
    package static func openInFinder(_ path: URL) -> Bool {
        let success = NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path.path)
        if !success {
            logger.warning("Reveal in Finder failed for path=\(path.path, privacy: .public)")
        }
        return success
    }

    @discardableResult
    @MainActor
    package static func openInCursor(_ path: URL) -> Bool {
        openInEditor(id: ExternalEditorTarget.cursor.id, path: path)
    }

    @discardableResult
    @MainActor
    package static func openInVSCode(_ path: URL) -> Bool {
        openInEditor(id: ExternalEditorTarget.vscode.id, path: path)
    }

    @discardableResult
    static func open(
        requests: [OpenRequest],
        runner: (OpenRequest) -> Bool = run
    ) -> Bool {
        for request in requests {
            if runner(request) {
                return true
            }
        }
        logger.warning("No external editor opener succeeded")
        return false
    }

    @discardableResult
    @MainActor
    static func openAsync(
        requests: [OpenRequest],
        runner: @escaping (OpenRequest) async -> Bool = runAsync
    ) async -> Bool {
        for request in requests {
            if await runner(request) {
                return true
            }
        }
        logger.warning("No external editor opener succeeded")
        return false
    }

    @discardableResult
    private static func run(_ request: OpenRequest) -> Bool {
        switch request {
        case .application(let bundleIdentifier, let targetPath):
            guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
                logger.debug(
                    "Editor app not registered for bundleID=\(bundleIdentifier, privacy: .public)"
                )
                return false
            }

            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open([targetPath], withApplicationAt: appURL, configuration: configuration) { _, error in
                if let error {
                    logger.error(
                        "Open with app bundleID=\(bundleIdentifier, privacy: .public) failed for path=\(targetPath.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
            return true
        case .command(let executableURL, let arguments):
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments
            do {
                try process.run()
                return true
            } catch {
                let commandName = arguments.first ?? "<unknown>"
                logger.error(
                    "Open in \(commandName, privacy: .public) failed for args=\(arguments.joined(separator: " "), privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                return false
            }
        }
    }

    @MainActor
    private static func runAsync(_ request: OpenRequest) async -> Bool {
        switch request {
        case .application(let bundleIdentifier, let targetPath):
            guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
                logger.debug(
                    "Editor app not registered for bundleID=\(bundleIdentifier, privacy: .public)"
                )
                return false
            }

            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            do {
                _ = try await NSWorkspace.shared.open(
                    [targetPath],
                    withApplicationAt: appURL,
                    configuration: configuration
                )
                return true
            } catch {
                logger.error(
                    "Open with app bundleID=\(bundleIdentifier, privacy: .public) failed for path=\(targetPath.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                return false
            }
        case .command:
            return run(request)
        }
    }
}
