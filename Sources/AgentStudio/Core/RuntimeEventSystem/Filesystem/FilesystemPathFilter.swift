import Foundation
import os

package enum FilesystemPathDisposition: Sendable, Equatable {
    case projected
    case gitObjectDatabase
    case gitInternal
    case ignoredByPolicy
}

/// Lightweight, cached filtering policy for filesystem projection payloads.
///
/// Current policy:
/// - discard `.git/objects` writes because unreachable object storage is not a repository-state change
/// - ignore `FETCH_HEAD` bookkeeping because it does not alter working-tree status inputs
/// - suppress `.git` internals from projection-facing changed-path payloads
/// - apply root-level `.gitignore` rules for projection payload suppression
package struct FilesystemPathFilter: Sendable {
    fileprivate static let logger = Logger(subsystem: "com.agentstudio", category: "FilesystemPathFilter")
    package static let empty = Self(ignoredRules: [])

    private let ignoredRules: [GitIgnoreRule]

    package var estimatedRetainedByteCount: Int {
        ignoredRules.reduce(32) { partialResult, rule in
            partialResult
                + rule.originalPattern.utf8.count
                + rule.compiledRegex.pattern.utf8.count
                + 64
        }
    }

    package static func load(forRootPath rootPath: URL) -> Self {
        let gitIgnorePath = rootPath.appending(path: ".gitignore")
        let fileContents: String
        do {
            fileContents = try String(contentsOf: gitIgnorePath, encoding: .utf8)
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileReadNoSuchFileError {
                return Self(ignoredRules: [])
            }
            logger.warning(
                "Failed to load .gitignore at \(gitIgnorePath.path, privacy: .public): domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public) reason=\(Self.gitIgnoreReadFailureReason(nsError), privacy: .public)"
            )
            return Self(ignoredRules: [])
        }

        let rules =
            fileContents
            .split(whereSeparator: \.isNewline)
            .compactMap { GitIgnoreRule(rawLine: String($0)) }
        return Self(ignoredRules: rules)
    }

    @concurrent nonisolated package static func loadOffExecutor(forRootPath rootPath: URL) async -> Self {
        load(forRootPath: rootPath)
    }

    package func classify(relativePath: String) -> FilesystemPathDisposition {
        if Self.isAgentStudioPrivateStagingRefPath(relativePath) {
            return .ignoredByPolicy
        }
        if Self.isFetchHeadBookkeepingPath(relativePath: relativePath) {
            return .ignoredByPolicy
        }
        if Self.isOriginConfigPath(relativePath: relativePath) {
            return .projected
        }
        let isOwnGitPath = Self.normalized(relativePath: relativePath).split(separator: "/").first == ".git"
        // The owning repository's Git directory stays observable even under broad
        // ignore rules. Nested repositories inherit their owning root's ignore policy.
        if !isOwnGitPath, isIgnored(relativePath: relativePath) {
            return .ignoredByPolicy
        }
        if Self.isGitObjectDatabase(relativePath: relativePath) {
            return .gitObjectDatabase
        }
        if Self.isGitInternal(relativePath: relativePath) {
            return .gitInternal
        }
        return .projected
    }

    package func isIgnored(relativePath: String) -> Bool {
        let normalizedPath = Self.normalized(relativePath: relativePath)
        guard !normalizedPath.isEmpty, normalizedPath != "." else { return false }

        let pathComponents = normalizedPath.split(separator: "/")
        for componentCount in 1...pathComponents.count {
            let candidatePath = pathComponents.prefix(componentCount).joined(separator: "/")
            if rulesIgnoreExactPath(candidatePath) {
                // Git cannot re-include a descendant while an ancestor directory
                // remains excluded, so an ignored prefix is terminal for this path.
                return true
            }
        }
        return false
    }

    private func rulesIgnoreExactPath(_ relativePath: String) -> Bool {
        var ignored = false
        for rule in ignoredRules {
            if rule.matches(relativePath: relativePath) {
                ignored = !rule.isNegated
            }
        }
        return ignored
    }

    package static func isGitInternal(relativePath: String) -> Bool {
        // v1 behavior: treat any path segment named ".git" as internal.
        // This may over-classify certain nested/module layouts; refine if needed later.
        let normalizedPath = normalized(relativePath: relativePath)
        guard !normalizedPath.isEmpty else { return false }
        let pathComponents = normalizedPath.split(separator: "/")
        return pathComponents.contains(".git")
    }

    package static func isOriginConfigPath(relativePath: String) -> Bool {
        normalized(relativePath: relativePath) == ".git/config"
    }

    private static func isGitObjectDatabase(relativePath: String) -> Bool {
        let pathComponents = normalized(relativePath: relativePath).split(separator: "/")
        guard pathComponents.count >= 2 else { return false }
        return pathComponents.indices.dropLast().contains { index in
            pathComponents[index] == ".git" && pathComponents[index + 1] == "objects"
        }
    }

    package static func isFetchHeadBookkeepingPath(relativePath: String) -> Bool {
        let pathComponents = normalized(relativePath: relativePath).split(separator: "/")
        guard pathComponents.contains(".git"), let fileName = pathComponents.last else {
            return false
        }
        return fileName == "FETCH_HEAD" || fileName == "FETCH_HEAD.lock"
    }

    package static func isAgentStudioPrivateStagingRefPath(_ path: String) -> Bool {
        // Normalization cannot introduce these bytes; every admitted form already contains them.
        guard path.utf8.firstRange(of: "refs/agentstudio/staged".utf8) != nil else {
            return false
        }
        let normalizedPath = normalized(relativePath: path)
        return normalizedPath == "refs/agentstudio/staged"
            || normalizedPath.hasPrefix("refs/agentstudio/staged/")
            || normalizedPath.hasSuffix("/refs/agentstudio/staged")
            || normalizedPath.utf8.firstRange(of: "/refs/agentstudio/staged/".utf8) != nil
    }

    private static func normalized(relativePath: String) -> String {
        var normalizedPath = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        while normalizedPath.hasPrefix("./") {
            normalizedPath.removeFirst(2)
        }
        while normalizedPath.hasPrefix("/") {
            normalizedPath.removeFirst()
        }
        return normalizedPath
    }

    private static func gitIgnoreReadFailureReason(_ error: NSError) -> String {
        if error.domain == NSCocoaErrorDomain {
            switch error.code {
            case NSFileReadNoPermissionError:
                return "fileReadNoPermission"
            case NSFileReadNoSuchFileError:
                return "fileReadNoSuchFile"
            case NSFileReadInapplicableStringEncodingError:
                return "fileReadEncoding"
            case NSFileReadCorruptFileError:
                return "fileReadCorrupt"
            default:
                break
            }
        }
        if error.domain == NSPOSIXErrorDomain {
            switch POSIXErrorCode(rawValue: Int32(error.code)) {
            case .EACCES?:
                return "permissionDenied"
            case .EPERM?:
                return "operationNotPermitted"
            case .ENOENT?:
                return "notFound"
            case .EMFILE?, .ENFILE?:
                return "tooManyOpenFiles"
            default:
                break
            }
        }
        return "unknown"
    }
}

package enum RepositoryLocalActivityPathClassifier {
    package static func qualifiesWorktreePath(
        relativePath: String,
        disposition: FilesystemPathDisposition
    ) -> Bool {
        let normalizedPath = normalized(relativePath)
        if normalizedPath == ".gitignore" {
            return true
        }
        if FilesystemPathFilter.isGitInternal(relativePath: normalizedPath) {
            return qualifiesGitMetadataPath(normalizedPath)
        }
        return disposition == .projected
    }

    package static func qualifiesGitMetadataPath(_ path: String) -> Bool {
        let normalizedPath = normalized(path)
        guard !FilesystemPathFilter.isAgentStudioPrivateStagingRefPath(normalizedPath) else {
            return false
        }
        guard !normalizedPath.hasSuffix(".lock") else { return false }

        let components = normalizedPath.split(separator: "/")
        guard let leaf = components.last else { return false }
        if leaf == "HEAD" || leaf == "index" || leaf == "FETCH_HEAD" || leaf == "packed-refs" {
            return true
        }
        return normalizedPath.contains("/refs/heads/")
            || normalizedPath.contains("/refs/remotes/")
            || normalizedPath.hasPrefix("refs/heads/")
            || normalizedPath.hasPrefix("refs/remotes/")
    }

    private static func normalized(_ path: String) -> String {
        var normalizedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while normalizedPath.hasPrefix("./") {
            normalizedPath.removeFirst(2)
        }
        while normalizedPath.hasSuffix("/") && normalizedPath.count > 1 {
            normalizedPath.removeLast()
        }
        return normalizedPath
    }
}

// NSRegularExpression is immutable and safe to share for matching after initialization.
// @unchecked Sendable is required specifically because compiledRegex is a Foundation reference type.
private struct GitIgnoreRule: @unchecked Sendable {
    let isNegated: Bool
    let anchoredToRoot: Bool
    let directoryOnly: Bool
    let originalPattern: String
    let compiledRegex: NSRegularExpression

    init?(rawLine: String) {
        let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !trimmed.hasPrefix("#") else { return nil }

        var workingLine = trimmed
        let isNegated = workingLine.hasPrefix("!")
        if isNegated {
            workingLine.removeFirst()
        }

        let anchoredToRoot = workingLine.hasPrefix("/")
        if anchoredToRoot {
            workingLine.removeFirst()
        }

        let directoryOnly = workingLine.hasSuffix("/")
        if directoryOnly {
            workingLine.removeLast()
        }

        guard !workingLine.isEmpty else { return nil }
        let regexPattern = Self.makeRegexPattern(
            pattern: workingLine,
            anchoredToRoot: anchoredToRoot,
            directoryOnly: directoryOnly
        )
        let compiledRegex: NSRegularExpression
        do {
            compiledRegex = try NSRegularExpression(pattern: regexPattern)
        } catch {
            FilesystemPathFilter.logger.warning(
                "Dropped invalid .gitignore rule '\(workingLine, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }

        self.isNegated = isNegated
        self.anchoredToRoot = anchoredToRoot
        self.directoryOnly = directoryOnly
        self.originalPattern = workingLine
        self.compiledRegex = compiledRegex
    }

    func matches(relativePath: String) -> Bool {
        let pathRange = NSRange(relativePath.startIndex..<relativePath.endIndex, in: relativePath)
        return compiledRegex.firstMatch(in: relativePath, options: [], range: pathRange) != nil
    }

    private static func makeRegexPattern(
        pattern: String,
        anchoredToRoot: Bool,
        directoryOnly: Bool
    ) -> String {
        let patternHasSlash = pattern.contains("/")
        let escapedPattern = globToRegex(pattern)
        let rootPrefix: String

        if anchoredToRoot {
            rootPrefix = "^"
        } else if patternHasSlash {
            rootPrefix = "^(?:.*/)?"
        } else {
            rootPrefix = "^(?:.*/)?"
        }

        if !patternHasSlash, !anchoredToRoot {
            let componentRegex = globToRegex(pattern)
            if directoryOnly {
                return "^(?:.*/)?\(componentRegex)(?:/.*)?$"
            }
            return "^(?:.*/)?\(componentRegex)$"
        }

        if directoryOnly {
            return "\(rootPrefix)\(escapedPattern)(?:/.*)?$"
        }

        return "\(rootPrefix)\(escapedPattern)$"
    }

    private static func globToRegex(_ pattern: String) -> String {
        var output = ""
        var index = pattern.startIndex

        while index < pattern.endIndex {
            let character = pattern[index]

            if character == "*" {
                let nextIndex = pattern.index(after: index)
                if nextIndex < pattern.endIndex, pattern[nextIndex] == "*" {
                    output.append(".*")
                    index = pattern.index(after: nextIndex)
                    continue
                }
                output.append("[^/]*")
                index = nextIndex
                continue
            }

            if character == "?" {
                output.append("[^/]")
                index = pattern.index(after: index)
                continue
            }

            if "\\.+()|{}[]^$".contains(character) {
                output.append("\\")
            }
            output.append(character)
            index = pattern.index(after: index)
        }

        return output
    }
}
