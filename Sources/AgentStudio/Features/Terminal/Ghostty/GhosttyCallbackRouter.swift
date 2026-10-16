import AgentStudioCore
import AgentStudioInfrastructure
import AppKit
import Foundation
import GhosttyKit

extension Ghostty {
    /// Owns the embedded Ghostty callback table and reconstructs Swift objects
    /// from userdata. `wakeup_cb` and `close_surface_cb` hop back to
    /// `@MainActor`, clipboard callbacks execute synchronously at the C boundary,
    /// and `action_cb` forwards the app pointer directly into `ActionRouter`.
    enum CallbackRouter {
        static func runtimeConfig(userdataPointer: UnsafeMutableRawPointer) -> ghostty_runtime_config_s {
            runtimeConfig(
                userdataPointer: userdataPointer,
                actionCallback: { appPtr, target, action in
                    guard let appPtr else {
                        ghosttyLogger.fault("Ghostty action callback dropped: app pointer was nil")
                        return false
                    }
                    guard let userdata = ghostty_app_userdata(appPtr) else { return false }
                    let context = Unmanaged<GhosttyCallbackContext>.fromOpaque(userdata).takeUnretainedValue()
                    return context.handling.handleAction(target: target, action: action)
                }
            )
        }

        static func runtimeConfig(
            userdataPointer: UnsafeMutableRawPointer,
            actionCallback: ghostty_runtime_action_cb
        ) -> ghostty_runtime_config_s {
            ghostty_runtime_config_s(
                userdata: userdataPointer,
                supports_selection_clipboard: true,
                wakeup_cb: { userdata in
                    guard let userdata else {
                        ghosttyLogger.error("Ghostty wakeup callback dropped: userdata was nil")
                        return
                    }
                    let context = Unmanaged<GhosttyCallbackContext>.fromOpaque(userdata).takeUnretainedValue()
                    context.wakeup()
                },
                action_cb: actionCallback,
                read_clipboard_cb: { userdata, location, state, mimes, count, list in
                    guard !list else { return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED }
                    guard let mimes, count > 0,
                        (0..<count).contains(where: { index in
                            mimes[index].map { String(cString: $0) == "text/plain" } ?? false
                        })
                    else { return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED }
                    return Self.readClipboard(userdata, location: location, state: state)
                },
                confirm_read_clipboard_cb: { userdata, content, state, request in
                    Self.confirmReadClipboard(userdata, content: content, state: state, request: request)
                },
                write_clipboard_cb: { userdata, location, content, len, confirm in
                    Self.writeClipboard(
                        userdata,
                        location: location,
                        content: content,
                        len: len,
                        confirm: confirm
                    )
                },
                close_surface_cb: { userdata, _ in
                    Self.closeSurface(userdata)
                }
            )
        }

        static func readClipboard(
            _ userdata: UnsafeMutableRawPointer?, location: ghostty_clipboard_e, state: UnsafeMutableRawPointer?
        ) -> ghostty_clipboard_read_result_e {
            guard let pasteboard = clipboardPasteboard(for: location) else { return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED }
            guard let userdata else { return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE }
            let surfaceView = Unmanaged<SurfaceView>.fromOpaque(userdata).takeUnretainedValue()
            guard let surface = surfaceView.surface else { return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE }
            guard let content = clipboardText(from: pasteboard) else { return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE }
            "text/plain".withCString { mime in
                content.withCString { bytes in
                    var item = ghostty_clipboard_content_s(mime: mime, data: bytes, len: content.utf8.count)
                    withUnsafePointer(to: &item) { itemPointer in
                        var completion = ghostty_clipboard_complete_s(
                            contents: itemPointer, contents_len: 1,
                            available: nil, available_len: 0,
                            confirmed: false, remember: false
                        )
                        ghostty_surface_complete_clipboard_request(surface, &completion, state)
                    }
                }
            }
            return GHOSTTY_CLIPBOARD_READ_STARTED
        }

        private static func confirmReadClipboard(
            _ userdata: UnsafeMutableRawPointer?, content: UnsafePointer<ghostty_clipboard_confirm_s>?,
            state: UnsafeMutableRawPointer?, request: ghostty_clipboard_request_e
        ) {
            guard let userdata else { return }
            let surfaceView = Unmanaged<SurfaceView>.fromOpaque(userdata).takeUnretainedValue()
            guard let surface = surfaceView.surface else { return }
            guard let content else {
                ghostty_surface_deny_clipboard_request(surface, state)
                return
            }
            // The owner explicitly retained existing automatic approval for this beta.
            // Do not persist a broader session grant.
            var completion = ghostty_clipboard_complete_s(
                contents: content.pointee.contents, contents_len: content.pointee.contents_len,
                available: content.pointee.available, available_len: content.pointee.available_len,
                confirmed: true, remember: false
            )
            ghostty_surface_complete_clipboard_request(surface, &completion, state)
        }

        // Confirmation-required writes retain the owner-approved beta auto-approval behavior.
        private static func writeClipboard(
            _ userdata: UnsafeMutableRawPointer?, location: ghostty_clipboard_e,
            content: UnsafePointer<ghostty_clipboard_content_s>?, len: Int, confirm: Bool
        ) {
            guard userdata != nil else {
                ghosttyLogger.debug("Ghostty writeClipboard callback dropped: userdata was nil")
                return
            }
            guard let content, len > 0 else {
                ghosttyLogger.debug("Ghostty writeClipboard callback dropped: clipboard content was empty")
                return
            }

            guard let pasteboard = clipboardPasteboard(for: location),
                let str = clipboardText(from: content, count: len)
            else { return }

            pasteboard.clearContents()
            pasteboard.setString(str, forType: .string)
        }

        static func clipboardPasteboard(for location: ghostty_clipboard_e) -> NSPasteboard? {
            switch location {
            case GHOSTTY_CLIPBOARD_STANDARD:
                return .general
            case GHOSTTY_CLIPBOARD_SELECTION:
                return NSPasteboard(name: .init("com.agentstudio.terminal.selection"))
            default:
                return nil
            }
        }

        static func clipboardText(from pasteboard: NSPasteboard) -> String? {
            pasteboard.string(forType: .string)
        }

        static func clipboardText(
            from content: UnsafePointer<ghostty_clipboard_content_s>, count: Int
        ) -> String? {
            var selectedText: String?
            for index in 0..<count {
                let item = content[index]
                guard let mime = item.mime, String(cString: mime) == "text/plain" else { continue }
                guard selectedText == nil else { return nil }
                if item.len == 0 {
                    selectedText = ""
                } else {
                    guard let data = item.data else { return nil }
                    guard
                        let text = String(bytes: UnsafeRawBufferPointer(start: data, count: item.len), encoding: .utf8)
                    else { return nil }
                    selectedText = text
                }
            }
            return selectedText
        }

        private static func closeSurface(_ userdata: UnsafeMutableRawPointer?) {
            guard let userdata else {
                ghosttyLogger.debug("Ghostty closeSurface callback dropped: userdata was nil")
                return
            }
            let surfaceView = Unmanaged<SurfaceView>.fromOpaque(userdata).takeUnretainedValue()
            _ = surfaceView.callbackHandling?.accept(
                .close(surfaceID: surfaceView.managedSurfaceID, viewObjectID: ObjectIdentifier(surfaceView))
            )
        }
    }
}
