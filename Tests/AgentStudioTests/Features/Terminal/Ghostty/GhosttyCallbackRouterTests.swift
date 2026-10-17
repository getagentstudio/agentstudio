import AgentStudioCore
import AgentStudioInfrastructure
import AppKit
import GhosttyKit
import Testing

@testable import AgentStudioTerminal

@MainActor
@Suite("Ghostty callback router", .serialized)
struct GhosttyCallbackRouterTests {
    private final class RoutedActionCapture {
        var actionTag: UInt32?
        var payload: GhosttyActionPayload?
        var handledResult: Bool?
    }

    @Test("readClipboard returns unavailable when no surface userdata is available")
    func readClipboard_withoutUserdata_returnsUnavailable() {
        let handled = Ghostty.CallbackRouter.readClipboard(
            nil,
            location: GHOSTTY_CLIPBOARD_STANDARD,
            state: nil
        )

        #expect(handled == GHOSTTY_CLIPBOARD_READ_UNAVAILABLE)
    }

    @Test("runtimeConfig read clipboard callback can invoke the helper path")
    func runtimeConfig_readClipboardCallback_invokesHelperPath() {
        let userdataPointer = UnsafeMutableRawPointer(bitPattern: 0x1)!
        let config = Ghostty.CallbackRouter.runtimeConfig(userdataPointer: userdataPointer)

        let handled = "text/plain".withCString { mime in
            var requestedMime: UnsafePointer<CChar>? = mime
            return withUnsafePointer(to: &requestedMime) { pointer in
                config.read_clipboard_cb(nil, GHOSTTY_CLIPBOARD_STANDARD, nil, pointer, 1, false)
            }
        }

        #expect(handled == GHOSTTY_CLIPBOARD_READ_UNAVAILABLE)
    }

    @Test("clipboard listing and unsupported representations do not read pasteboard data")
    func unsupportedClipboardRequestsAreRejected() {
        let config = Ghostty.CallbackRouter.runtimeConfig(
            userdataPointer: UnsafeMutableRawPointer(bitPattern: 0x1)!
        )
        #expect(
            config.read_clipboard_cb(nil, GHOSTTY_CLIPBOARD_STANDARD, nil, nil, 0, true)
                == GHOSTTY_CLIPBOARD_READ_UNSUPPORTED)
        let result = "image/png".withCString { mime in
            var requestedMime: UnsafePointer<CChar>? = mime
            return withUnsafePointer(to: &requestedMime) { pointer in
                config.read_clipboard_cb(nil, GHOSTTY_CLIPBOARD_STANDARD, nil, pointer, 1, false)
            }
        }
        #expect(result == GHOSTTY_CLIPBOARD_READ_UNSUPPORTED)
    }

    @Test("clipboard locations keep selection separate and reject primary")
    func clipboardLocationsRemainSeparate() throws {
        let standard = try #require(Ghostty.CallbackRouter.clipboardPasteboard(for: GHOSTTY_CLIPBOARD_STANDARD))
        let selection = try #require(Ghostty.CallbackRouter.clipboardPasteboard(for: GHOSTTY_CLIPBOARD_SELECTION))
        #expect(standard.name == NSPasteboard.general.name)
        #expect(selection.name != standard.name)
        #expect(Ghostty.CallbackRouter.clipboardPasteboard(for: GHOSTTY_CLIPBOARD_PRIMARY) == nil)
    }

    @Test("missing text differs from an available empty string")
    func missingClipboardTextIsUnavailable() {
        let pasteboard = NSPasteboard(name: .init("agentstudio-test-\(UUIDv7.generate())"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        #expect(Ghostty.CallbackRouter.clipboardText(from: pasteboard) == nil)
        pasteboard.setString("", forType: .string)
        #expect(Ghostty.CallbackRouter.clipboardText(from: pasteboard)?.isEmpty == true)
    }

    @Test("typed writes select plain text and preserve its complete byte length")
    func clipboardWritesSelectPlainText() {
        let expected = "π\0雪"
        Array(expected.utf8).withUnsafeBytes { bytes in
            "image/png".withCString { imageMime in
                "text/plain".withCString { textMime in
                    let image = ghostty_clipboard_content_s(mime: imageMime, data: nil, len: 0)
                    let text = ghostty_clipboard_content_s(
                        mime: textMime, data: bytes.baseAddress?.assumingMemoryBound(to: CChar.self), len: bytes.count
                    )
                    [image, text].withUnsafeBufferPointer { contents in
                        #expect(Ghostty.CallbackRouter.clipboardText(from: contents.baseAddress!, count: 2) == expected)
                        #expect(Ghostty.CallbackRouter.clipboardText(from: contents.baseAddress!, count: 1) == nil)
                    }
                    [text, text].withUnsafeBufferPointer { contents in
                        #expect(Ghostty.CallbackRouter.clipboardText(from: contents.baseAddress!, count: 2) == nil)
                    }
                    let empty = ghostty_clipboard_content_s(mime: textMime, data: nil, len: 0)
                    [empty].withUnsafeBufferPointer { contents in
                        #expect(
                            Ghostty.CallbackRouter.clipboardText(from: contents.baseAddress!, count: 1)?.isEmpty == true
                        )
                    }
                }
            }
        }
    }

    @Test("runtimeConfig action callback copies borrowed title before invoking the typed route")
    func runtimeConfig_actionCallback_copiesBorrowedTitleBeforeInvokingTypedRoute() throws {
        let routeCapture = RoutedActionCapture()
        let appHandle = Unmanaged.passUnretained(routeCapture).toOpaque()
        let runtimeConfig = Self.metadataRuntimeConfig(capture: routeCapture)
        let target = ghostty_target_s(
            tag: GHOSTTY_TARGET_APP,
            target: ghostty_target_u(surface: nil)
        )
        let originalTitle = "callback-owned-title"
        var borrowedTitle = Array(originalTitle.utf8CString)

        let handled = borrowedTitle.withUnsafeMutableBufferPointer { titleBuffer in
            let action = ghostty_action_s(
                tag: GHOSTTY_ACTION_SET_TITLE,
                action: ghostty_action_u(
                    set_title: ghostty_action_set_title_s(title: titleBuffer.baseAddress)
                )
            )
            let handled = runtimeConfig.action_cb(appHandle, target, action)
            titleBuffer[0] = 88
            return handled
        }

        #expect(handled)
        #expect(routeCapture.actionTag == UInt32(GHOSTTY_ACTION_SET_TITLE.rawValue))
        #expect(try #require(routeCapture.payload) == .titleChanged(originalTitle))
        #expect(routeCapture.handledResult == true)
    }

    @Test("runtimeConfig action callback copies borrowed working directory before returning")
    func runtimeConfig_actionCallback_copiesBorrowedWorkingDirectory() throws {
        let routeCapture = RoutedActionCapture()
        let appHandle = Unmanaged.passUnretained(routeCapture).toOpaque()
        let runtimeConfig = Self.metadataRuntimeConfig(capture: routeCapture)
        let target = ghostty_target_s(tag: GHOSTTY_TARGET_APP, target: ghostty_target_u(surface: nil))
        let originalWorkingDirectory = "/tmp/callback-owned-directory"
        var borrowedWorkingDirectory = Array(originalWorkingDirectory.utf8CString)

        let handled = borrowedWorkingDirectory.withUnsafeMutableBufferPointer { directoryBuffer in
            let action = ghostty_action_s(
                tag: GHOSTTY_ACTION_PWD,
                action: ghostty_action_u(pwd: .init(pwd: directoryBuffer.baseAddress))
            )
            let handled = runtimeConfig.action_cb(appHandle, target, action)
            directoryBuffer[0] = 88
            return handled
        }

        #expect(handled)
        #expect(routeCapture.actionTag == UInt32(GHOSTTY_ACTION_PWD.rawValue))
        #expect(try #require(routeCapture.payload) == .cwdChanged(originalWorkingDirectory))
        #expect(routeCapture.handledResult == true)
    }

    @Test("nil working directory preserves false handled result and produces no exact metadata work")
    func runtimeConfig_actionCallback_nilWorkingDirectoryDoesNotRouteExactMetadata() {
        let routeCapture = RoutedActionCapture()
        let appHandle = Unmanaged.passUnretained(routeCapture).toOpaque()
        let runtimeConfig = Self.metadataRuntimeConfig(capture: routeCapture)
        let target = ghostty_target_s(tag: GHOSTTY_TARGET_APP, target: ghostty_target_u(surface: nil))
        let action = ghostty_action_s(
            tag: GHOSTTY_ACTION_PWD,
            action: ghostty_action_u(pwd: .init(pwd: nil))
        )

        let handled = runtimeConfig.action_cb(appHandle, target, action)

        #expect(!handled)
        #expect(routeCapture.actionTag == nil)
        #expect(routeCapture.payload == nil)
        #expect(routeCapture.handledResult == nil)
    }

    private static func metadataRuntimeConfig(capture: RoutedActionCapture) -> ghostty_runtime_config_s {
        let appHandle = Unmanaged.passUnretained(capture).toOpaque()
        let runtimeConfig = Ghostty.CallbackRouter.runtimeConfig(
            userdataPointer: appHandle,
            actionCallback: { appPtr, _, action in
                guard let appPtr else { return false }
                let routeCapture = Unmanaged<RoutedActionCapture>.fromOpaque(appPtr).takeUnretainedValue()
                guard case .payload(let payload, let handled) = GhosttyCallbackPayloadDecoder.decode(action) else {
                    return false
                }
                routeCapture.actionTag = UInt32(truncatingIfNeeded: action.tag.rawValue)
                routeCapture.payload = payload
                routeCapture.handledResult = handled
                return handled
            }
        )
        return runtimeConfig
    }
}
