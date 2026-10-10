import AgentStudioCore
import AgentStudioInfrastructure
import AppKit
import Foundation
import GhosttyKit
import os

/// Logger for Ghostty-related operations
package let ghosttyLogger = Logger(subsystem: "com.agentstudio", category: "Ghostty")

/// Namespace for all Ghostty-related types
package enum Ghostty {

}

extension Ghostty {
    /// Thin composition root for the embedded Ghostty host subsystem.
    @MainActor
    package final class App {
        let callbackContext: GhosttyCallbackContext
        /// The raw Ghostty app lifetime owner.
        private var appHandle: AppHandle?
        private let focusSynchronizer: AppFocusSynchronizer

        /// The raw Ghostty app handle exposed to existing callers.
        var app: ghostty_app_t? {
            appHandle?.app
        }

        package var nativeHandleIsAvailable: Bool { appHandle != nil }

        @MainActor
        package init(callbackHandling: ActionRouter) {
            self.focusSynchronizer = AppFocusSynchronizer()
            self.callbackContext = GhosttyCallbackContext(handling: callbackHandling)
            self.callbackContext.installEngineTarget(self)

            // Create runtime config with callbacks
            let userdataPointer = Unmanaged.passUnretained(callbackContext).toOpaque()
            let runtimeConfig = CallbackRouter.runtimeConfig(userdataPointer: userdataPointer)

            self.appHandle = AppHandle(
                runtimeConfig: runtimeConfig,
                callbackContext: callbackContext
            )

            guard let appHandle else {
                ghosttyLogger.error("Ghostty.App init failed: AppHandle creation returned nil")
                return
            }

            focusSynchronizer.updateAppHandle(appHandle.app)

            // Start unfocused; activation notifications synchronize real app focus state.
            ghostty_app_set_focus(appHandle.app, false)

            ghosttyLogger.info("Ghostty app initialized successfully")
        }

        isolated deinit {
            // Native views retain this wrapper until after their per-surface free.
            // Conditional wrapper release therefore has no remaining native surfaces.
            let context = callbackContext
            context.handling.closeAdmission()
            focusSynchronizer.clearAppHandleForDeinit()
            let handleToRelease = appHandle
            Task { @MainActor in
                await context.handling.retire()
                context.clearEngineTarget()
                // AppHandle retains the context through both native frees.
                withExtendedLifetime(handleToRelease) {}
            }
        }

        /// Process pending ghostty events.
        @MainActor
        func tick() {
            appHandle?.tick()
        }

        @MainActor
        func hostConfigSnapshot() -> GhosttyHostConfigSnapshot {
            appHandle?.hostConfigSnapshot() ?? GhosttyHostConfigSnapshot(configHandle: nil)
        }

        @MainActor
        package func bindApplicationLifecycleStore(_ appLifecycleStore: AppLifecycleAtom) {
            focusSynchronizer.bindApplicationLifecycleStore(appLifecycleStore)
        }

    }
}
