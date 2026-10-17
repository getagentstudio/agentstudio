import AgentStudioCore
import AgentStudioInfrastructure
import Foundation
import GhosttyKit
import Testing

@testable import AgentStudioTerminal

@MainActor
@Suite("Terminal hyperlink dispatch", .serialized)
struct TerminalHyperlinkDispatchTests {
    @Test("Ghostty OSC 8 hyperlink kind survives event translation")
    func preservesOSC8Kind() {
        let translated = GhosttyActionTranslation.translate(
            actionTag: UInt32(GHOSTTY_ACTION_OPEN_URL.rawValue),
            payload: .openURL(
                url: "https://example.com/terminal-link",
                kindRawValue: UInt32(GHOSTTY_ACTION_OPEN_URL_KIND_OSC8.rawValue)
            )
        )
        #expect(translated == .openURLRequested(url: "https://example.com/terminal-link", kind: .osc8))
    }

    @Test("each clicked URL kind opens once through the native handler")
    func opensEveryKindOnceWithoutReplay() async {
        var opened: [String] = []
        let runtime = TerminalRuntime(
            paneId: .generateUUIDv7(),
            metadata: PaneMetadata(title: "Hyperlink"),
            paneEventBus: EventBus<RuntimeEnvelope>(),
            surfaceCommandDispatcher: TerminalFixtureSurfaceCommands(),
            openExternalURL: { opened.append($0) }
        )
        runtime.transitionToReady()
        let kinds: [OpenURLKind] = [.unknown, .text, .html, .osc8]
        for (index, kind) in kinds.enumerated() {
            runtime.handleGhosttyEvent(.openURLRequested(url: "https://example.com/\(index)", kind: kind))
        }
        #expect(opened == (0..<4).map { "https://example.com/\($0)" })
        let replay = await runtime.eventsSince(seq: 0)
        #expect(replay.events.isEmpty)
        #expect(opened.count == 4)
        _ = await runtime.shutdown(timeout: .seconds(1))
        runtime.handleGhosttyEvent(.openURLRequested(url: "https://example.com/stale", kind: .osc8))
        #expect(opened.count == 4)
    }

    @Test("clicked web, custom, and file targets go directly to the default handler")
    func opensTargetsThroughSystemHandler() {
        let targets = [
            "https://example.com/path?q=terminal#section",
            "mailto:developer@example.com",
            "vscode://file/tmp/example.swift",
            "file:///tmp/example.txt",
            "/tmp/path with spaces/example.txt",
            "~/Documents/example.txt",
        ]
        var opened: [URL] = []
        for target in targets {
            TerminalExternalURLOpener.open(
                target,
                using: {
                    opened.append($0)
                    return true
                })
        }
        #expect(opened.count == targets.count)
        #expect(opened[0] == URL(string: targets[0]))
        #expect(opened[1] == URL(string: targets[1]))
        #expect(opened[2] == URL(string: targets[2]))
        #expect(opened[3] == URL(string: targets[3]))
        #expect(opened[4].path == targets[4])
        #expect(opened[5] == URL(fileURLWithPath: NSString(string: targets[5]).standardizingPath))
        TerminalExternalURLOpener.open(
            "",
            using: { _ in
                Issue.record("An empty target must not open the working directory")
                return false
            })
    }
}
