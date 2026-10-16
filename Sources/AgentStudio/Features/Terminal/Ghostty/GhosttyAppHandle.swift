import AgentStudioCore
import AgentStudioInfrastructure
import Foundation
import GhosttyKit

extension Ghostty {
    /// Owns the raw Ghostty app/config lifetime and exposes the minimal API
    /// needed by the host composition root.
    final class AppHandle {
        private let appHandle: ghostty_app_t
        private let configHandle: ghostty_config_t
        private let callbackContext: GhosttyCallbackContext
        static let disableDefaultConfigEnvironmentKey = "AGENTSTUDIO_GHOSTTY_DISABLE_DEFAULT_CONFIG"
        static let disableVsyncEnvironmentKey = "AGENTSTUDIO_GHOSTTY_DISABLE_VSYNC"
        static let baseOverrideContents = """
            scroll-to-bottom = no-keystroke, no-output
            keybind = cmd+k=unbind
            # Agent Studio owns workspace and window structure.
            keybind = cmd+n=unbind
            keybind = cmd+t=unbind
            keybind = cmd+d=unbind
            keybind = cmd+shift+d=unbind
            keybind = cmd+w=unbind
            keybind = cmd+alt+w=unbind
            keybind = cmd+shift+w=unbind
            keybind = cmd+alt+shift+w=unbind
            keybind = cmd+shift+[=unbind
            keybind = cmd+shift+]=unbind
            keybind = cmd+[=unbind
            keybind = cmd+]=unbind
            keybind = cmd+alt+physical:up=unbind
            keybind = cmd+alt+physical:down=unbind
            keybind = cmd+alt+physical:left=unbind
            keybind = cmd+alt+physical:right=unbind
            keybind = cmd+ctrl+physical:up=unbind
            keybind = cmd+ctrl+physical:down=unbind
            keybind = cmd+ctrl+physical:left=unbind
            keybind = cmd+ctrl+physical:right=unbind
            keybind = cmd+ctrl+==unbind
            keybind = cmd+shift+enter=unbind
            keybind = cmd+enter=unbind
            keybind = cmd+ctrl+f=unbind
            keybind = cmd+physical:one=unbind
            keybind = cmd+physical:two=unbind
            keybind = cmd+physical:three=unbind
            keybind = cmd+physical:four=unbind
            keybind = cmd+physical:five=unbind
            keybind = cmd+physical:six=unbind
            keybind = cmd+physical:seven=unbind
            keybind = cmd+physical:eight=unbind
            keybind = cmd+1=unbind
            keybind = cmd+2=unbind
            keybind = cmd+3=unbind
            keybind = cmd+4=unbind
            keybind = cmd+5=unbind
            keybind = cmd+6=unbind
            keybind = cmd+7=unbind
            keybind = cmd+8=unbind
            keybind = cmd+9=unbind
            keybind = ctrl+tab=unbind
            keybind = ctrl+shift+tab=unbind
            """

        var app: ghostty_app_t {
            appHandle
        }

        static func overrideContents(
            environment: [String: String] = ProcessInfo.processInfo.environment,
            isDebugBuild: Bool = AppDataPaths.isDebugBuild
        ) -> String {
            var contents = baseOverrideContents
            if AppDataPaths.allowsDebugHarnessEnvironmentOverrides(
                environment: environment,
                isDebugBuild: isDebugBuild
            ),
                environment[disableVsyncEnvironmentKey] == "1"
            {
                contents += "\nwindow-vsync = false\n"
            }
            return contents
        }

        private static func writeGhosttyOverrideFile(
            environment: [String: String] = ProcessInfo.processInfo.environment,
            isDebugBuild: Bool = AppDataPaths.isDebugBuild
        ) throws -> URL {
            let overrideURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("agent-studio-ghostty-overrides-\(UUID().uuidString).conf")
            try overrideContents(environment: environment, isDebugBuild: isDebugBuild).write(
                to: overrideURL,
                atomically: true,
                encoding: .utf8
            )
            return overrideURL
        }

        init?(runtimeConfig: ghostty_runtime_config_s, callbackContext: GhosttyCallbackContext) {
            guard let config = ghostty_config_new() else {
                ghosttyLogger.error("Failed to create ghostty config")
                return nil
            }

            let environment = ProcessInfo.processInfo.environment
            if AppDataPaths.allowsDebugHarnessEnvironmentOverrides(environment: environment),
                environment[Self.disableDefaultConfigEnvironmentKey] == "1"
            {
                RestoreTrace.log("Ghostty default config loading disabled by environment")
            } else {
                ghostty_config_load_default_files(config)
            }
            do {
                let overrideURL = try Self.writeGhosttyOverrideFile(environment: environment)
                overrideURL.path.withCString { path in
                    ghostty_config_load_file(config, path)
                }
            } catch {
                ghosttyLogger.error(
                    "Failed to write Ghostty scroll behavior override file: \(error.localizedDescription, privacy: .public). Host follow-bottom behavior may degrade."
                )
            }
            ghostty_config_finalize(config)

            var mutableRuntimeConfig = runtimeConfig
            guard let app = ghostty_app_new(&mutableRuntimeConfig, config) else {
                ghosttyLogger.error("Failed to create ghostty app")
                ghostty_config_free(config)
                return nil
            }

            self.appHandle = app
            self.configHandle = config
            self.callbackContext = callbackContext
        }

        deinit {
            withExtendedLifetime(callbackContext) {
                ghostty_app_free(appHandle)
                ghostty_config_free(configHandle)
            }
        }

        @MainActor
        func tick() {
            ghostty_app_tick(appHandle)
        }

        @MainActor
        func hostConfigSnapshot() -> GhosttyHostConfigSnapshot {
            GhosttyHostConfigSnapshot(configHandle: configHandle)
        }
    }
}
