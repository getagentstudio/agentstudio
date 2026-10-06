import Foundation
import GhosttyKit
import Testing

@testable import AgentStudioTerminal

@Suite("Ghostty event routing coverage", .serialized)
@MainActor
struct GhosttyEventRoutingCoverageTests {
    @Test("upstream action vocabulary has no unmapped values")
    func upstreamActionVocabularyHasNoUnmappedValues() throws {
        let headerURL = try GhosttyXCFrameworkHeaderResolver.headerURL(
            in: URL(filePath: "Frameworks/GhosttyKit.xcframework", directoryHint: .isDirectory),
            hostArchitecture: GhosttyXCFrameworkHeaderResolver.currentHostArchitecture
        )
        let header = try String(
            contentsOf: headerURL,
            encoding: .utf8)
        let enumEnd = try #require(header.range(of: "} ghostty_action_tag_e;"))
        let enumStart = try #require(header[..<enumEnd.lowerBound].range(of: "typedef enum {", options: .backwards))
        let entries = header[enumStart.upperBound..<enumEnd.lowerBound]
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        // Fail closed if upstream changes from implicit contiguous C enum values.
        for entry in entries {
            #expect(entry.range(of: "^GHOSTTY_ACTION_[A-Z0-9_]+$", options: .regularExpression) != nil)
        }
        let upstreamValues = Set(entries.indices.map { UInt32($0) })
        let localValues = GhosttyActionTag.allCases.map(\.rawValue)
        #expect(Set(localValues) == upstreamValues)
        #expect(localValues.count == Set(localValues).count)

        let mapping = try String(
            contentsOfFile: "Sources/AgentStudio/Features/Terminal/Ghostty/GhosttyActionTag.swift", encoding: .utf8)
        let constants = try NSRegularExpression(pattern: "GHOSTTY_ACTION_[A-Z0-9_]+")
        let mappedNames = constants.matches(in: mapping, range: NSRange(mapping.startIndex..., in: mapping))
            .compactMap { Range($0.range, in: mapping).map { String(mapping[$0]) } }
        #expect(Set(mappedNames) == Set(entries))
        #expect(mappedNames.count == entries.count)
    }

    @Test("upstream window resize is consumed without forwarding host geometry")
    func upstreamWindowResizeIsIntercepted() throws {
        let rawTag = UInt32(GHOSTTY_ACTION_RESIZE_WINDOW.rawValue)
        let tag = try #require(GhosttyActionTag(rawValue: rawTag))
        #expect(Ghostty.ActionRouter.interceptedTags.contains(tag))
        #expect(!Ghostty.ActionRouter.unsupportedTags.contains(tag))
        #expect(Ghostty.ActionRouter.signalClass(for: tag) == .deferred)
        #expect(GhosttyAdapter.shared.translate(actionTag: rawTag) == .unhandled(tag: rawTag))
        let appHandle = try #require(UnsafeMutableRawPointer(bitPattern: 1))
        let handled = Ghostty.ActionRouter.handleAction(
            appHandle,
            target: ghostty_target_s(tag: GHOSTTY_TARGET_APP, target: ghostty_target_u(surface: nil)),
            action: ghostty_action_s(tag: GHOSTTY_ACTION_RESIZE_WINDOW, action: ghostty_action_u()),
            routingLookupProvider: {
                Issue.record("Window resize must not resolve terminal geometry")
                return SurfaceManager.shared
            },
            metadataActionRouter: { _, _, _, _ in
                Issue.record("Window resize must not publish metadata")
                return true
            }
        )
        #expect(handled)
    }

    @Test("header resolution accepts a universal macOS library")
    func headerResolutionAcceptsUniversalMacOSLibrary() throws {
        let frameworkURL = URL(filePath: "/fixture/GhosttyKit.xcframework", directoryHint: .isDirectory)
        let headerURL = try GhosttyXCFrameworkHeaderResolver.headerURL(
            in: frameworkURL,
            hostArchitecture: "arm64",
            manifestData: try manifestData(
                libraries: [
                    .init(
                        libraryIdentifier: "macos-arm64_x86_64",
                        headersPath: "Headers",
                        supportedArchitectures: ["arm64", "x86_64"],
                        supportedPlatform: "macos")
                ])
        )

        #expect(
            headerURL
                == frameworkURL.appending(
                    path: "macos-arm64_x86_64/Headers/GhosttyKit/ghostty.h", directoryHint: .notDirectory))
    }

    @Test("header resolution accepts a native macOS library")
    func headerResolutionAcceptsNativeMacOSLibrary() throws {
        let frameworkURL = URL(filePath: "/fixture/GhosttyKit.xcframework", directoryHint: .isDirectory)
        let headerURL = try GhosttyXCFrameworkHeaderResolver.headerURL(
            in: frameworkURL,
            hostArchitecture: "arm64",
            manifestData: try manifestData(
                libraries: [
                    .init(
                        libraryIdentifier: "macos-arm64",
                        headersPath: "Headers",
                        supportedArchitectures: ["arm64"],
                        supportedPlatform: "macos")
                ])
        )

        #expect(
            headerURL
                == frameworkURL.appending(
                    path: "macos-arm64/Headers/GhosttyKit/ghostty.h", directoryHint: .notDirectory))
    }

    @Test("header resolution rejects a manifest without a matching host library")
    func headerResolutionRejectsMissingHostLibrary() throws {
        let manifestData = try manifestData(
            libraries: [
                .init(
                    libraryIdentifier: "macos-x86_64",
                    headersPath: "Headers",
                    supportedArchitectures: ["x86_64"],
                    supportedPlatform: "macos")
            ])

        #expect(throws: GhosttyXCFrameworkHeaderResolutionError.missingHostLibrary) {
            try GhosttyXCFrameworkHeaderResolver.headerURL(
                in: URL(filePath: "/fixture/GhosttyKit.xcframework", directoryHint: .isDirectory),
                hostArchitecture: "arm64",
                manifestData: manifestData
            )
        }
    }

    @Test("header resolution rejects ambiguous matching host libraries")
    func headerResolutionRejectsAmbiguousHostLibraries() throws {
        let manifestData = try manifestData(
            libraries: [
                .init(
                    libraryIdentifier: "macos-arm64",
                    headersPath: "Headers",
                    supportedArchitectures: ["arm64"],
                    supportedPlatform: "macos"),
                .init(
                    libraryIdentifier: "macos-arm64-alternate",
                    headersPath: "Headers",
                    supportedArchitectures: ["arm64"],
                    supportedPlatform: "macos"),
            ])

        #expect(throws: GhosttyXCFrameworkHeaderResolutionError.ambiguousHostLibraries) {
            try GhosttyXCFrameworkHeaderResolver.headerURL(
                in: URL(filePath: "/fixture/GhosttyKit.xcframework", directoryHint: .isDirectory),
                hostArchitecture: "arm64",
                manifestData: manifestData
            )
        }
    }

    @Test(
        "unsupported upstream actions translate safely",
        arguments: [
            GhosttyActionTag.exportTerminalIO, .setWindowTitle, .selectionChanged, .moveTabToNewWindow,
        ])
    func unsupportedUpstreamActionsTranslateSafely(tag: GhosttyActionTag) {
        #expect(Ghostty.ActionRouter.unsupportedTags.contains(tag))
        #expect(GhosttyAdapter.shared.translate(actionTag: tag) == .unhandled(tag: tag.rawValue))
        #expect(GhosttyAdapter.shared.translate(actionTag: tag.rawValue) == .unhandled(tag: tag.rawValue))
    }

    @Test("every known Ghostty action tag has one explicit routing decision")
    func everyKnownGhosttyActionTag_hasExplicitRoutingDecision() {
        let accountedTags =
            Ghostty.ActionRouter.explicitlyRoutedTags
            .union(Ghostty.ActionRouter.deferredTags)
            .union(Ghostty.ActionRouter.interceptedTags)
            .union(Ghostty.ActionRouter.unsupportedTags)

        #expect(accountedTags == Set(GhosttyActionTag.allCases))
    }

    private func manifestData(libraries: [GhosttyXCFrameworkLibrary]) throws -> Data {
        try PropertyListEncoder().encode(GhosttyXCFrameworkManifest(availableLibraries: libraries))
    }
}

private enum GhosttyXCFrameworkHeaderResolutionError: Error, Equatable {
    case ambiguousHostLibraries
    case missingHostLibrary
}

private enum GhosttyXCFrameworkHeaderResolver {
    static var currentHostArchitecture: String {
        #if arch(arm64)
            "arm64"
        #elseif arch(x86_64)
            "x86_64"
        #else
            #error("Unsupported macOS host architecture")
        #endif
    }

    static func headerURL(
        in frameworkURL: URL,
        hostArchitecture: String,
        manifestData: Data? = nil
    ) throws -> URL {
        let resolvedManifestData =
            try manifestData
            ?? Data(contentsOf: frameworkURL.appending(path: "Info.plist", directoryHint: .notDirectory))
        let manifest = try PropertyListDecoder().decode(GhosttyXCFrameworkManifest.self, from: resolvedManifestData)
        let matchingLibraries = manifest.availableLibraries.filter { library in
            library.supportedPlatform == "macos"
                && library.supportedArchitectures.contains(hostArchitecture)
        }
        guard let matchingLibrary = matchingLibraries.first else {
            throw GhosttyXCFrameworkHeaderResolutionError.missingHostLibrary
        }
        guard matchingLibraries.count == 1 else {
            throw GhosttyXCFrameworkHeaderResolutionError.ambiguousHostLibraries
        }
        return
            frameworkURL
            .appending(path: matchingLibrary.libraryIdentifier, directoryHint: .isDirectory)
            .appending(path: matchingLibrary.headersPath, directoryHint: .isDirectory)
            .appending(path: "GhosttyKit", directoryHint: .isDirectory)
            .appending(path: "ghostty.h", directoryHint: .notDirectory)
    }
}

private struct GhosttyXCFrameworkManifest: Codable {
    let availableLibraries: [GhosttyXCFrameworkLibrary]

    enum CodingKeys: String, CodingKey {
        case availableLibraries = "AvailableLibraries"
    }
}

private struct GhosttyXCFrameworkLibrary: Codable {
    let libraryIdentifier: String
    let headersPath: String
    let supportedArchitectures: [String]
    let supportedPlatform: String

    enum CodingKeys: String, CodingKey {
        case headersPath = "HeadersPath"
        case libraryIdentifier = "LibraryIdentifier"
        case supportedArchitectures = "SupportedArchitectures"
        case supportedPlatform = "SupportedPlatform"
    }
}
