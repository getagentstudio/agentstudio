import AgentStudioInfrastructure
import Testing

@testable import AgentStudioTerminal

@Suite("GhosttyAppHandle", .serialized)
@MainActor
struct GhosttyAppHandleTests {
    @Test("ghostty config override removes cmd-k clear scrollback binding")
    func configOverrideRemovesCmdKClearScrollbackBinding() {
        let overrideContents = Ghostty.AppHandle.overrideContents()

        #expect(overrideContents.contains("keybind = cmd+k=unbind"))
    }

    @Test("ghostty config override unbinds macOS workspace structure defaults")
    func configOverrideUnbindsMacOSWorkspaceStructureDefaults() {
        let overrideContents = Ghostty.AppHandle.overrideContents()
        let expectedUnbinds = [
            "keybind = cmd+n=unbind",
            "keybind = cmd+t=unbind",
            "keybind = cmd+d=unbind",
            "keybind = cmd+shift+d=unbind",
            "keybind = cmd+w=unbind",
            "keybind = cmd+alt+w=unbind",
            "keybind = cmd+shift+w=unbind",
            "keybind = cmd+alt+shift+w=unbind",
            "keybind = cmd+shift+[=unbind",
            "keybind = cmd+shift+]=unbind",
            "keybind = cmd+[=unbind",
            "keybind = cmd+]=unbind",
            "keybind = cmd+alt+physical:up=unbind",
            "keybind = cmd+alt+physical:down=unbind",
            "keybind = cmd+alt+physical:left=unbind",
            "keybind = cmd+alt+physical:right=unbind",
            "keybind = cmd+ctrl+physical:up=unbind",
            "keybind = cmd+ctrl+physical:down=unbind",
            "keybind = cmd+ctrl+physical:left=unbind",
            "keybind = cmd+ctrl+physical:right=unbind",
            "keybind = cmd+ctrl+==unbind",
            "keybind = cmd+shift+enter=unbind",
            "keybind = cmd+enter=unbind",
            "keybind = cmd+ctrl+f=unbind",
            "keybind = cmd+9=unbind",
            "keybind = ctrl+tab=unbind",
            "keybind = ctrl+shift+tab=unbind",
        ]
        let tabNumberUnbinds = (1...8).flatMap { number in
            [
                "keybind = cmd+physical:\(Self.ghosttyNumberTrigger(for: number))=unbind",
                "keybind = cmd+\(number)=unbind",
            ]
        }

        for unbind in expectedUnbinds + tabNumberUnbinds {
            #expect(overrideContents.contains(unbind), "Missing Ghostty default unbind: \(unbind)")
        }
    }

    private static func ghosttyNumberTrigger(for number: Int) -> String {
        switch number {
        case 1: "one"
        case 2: "two"
        case 3: "three"
        case 4: "four"
        case 5: "five"
        case 6: "six"
        case 7: "seven"
        case 8: "eight"
        default: preconditionFailure("Only Ghostty's default Cmd+1 through Cmd+8 bindings are supported")
        }
    }

    @Test("ghostty config override disables vsync when requested")
    func configOverrideDisablesVsyncWhenRequested() {
        let overrideContents = Ghostty.AppHandle.overrideContents(
            environment: [
                Ghostty.AppHandle.disableVsyncEnvironmentKey: "1",
                AppDataPaths.traceProofTokenEnvironmentKey: "test-proof-token",
            ]
        )

        #expect(overrideContents.contains("window-vsync = false"))
    }

    @Test("ghostty config override ignores vsync env without debug proof token")
    func configOverrideIgnoresVsyncWithoutDebugProofToken() {
        let overrideContents = Ghostty.AppHandle.overrideContents(
            environment: [Ghostty.AppHandle.disableVsyncEnvironmentKey: "1"]
        )

        #expect(!overrideContents.contains("window-vsync = false"))
    }

    @Test("ghostty config override ignores vsync env for release builds")
    func configOverrideIgnoresVsyncForReleaseBuilds() {
        let overrideContents = Ghostty.AppHandle.overrideContents(
            environment: [
                Ghostty.AppHandle.disableVsyncEnvironmentKey: "1",
                AppDataPaths.traceProofTokenEnvironmentKey: "test-proof-token",
            ],
            isDebugBuild: false
        )

        #expect(!overrideContents.contains("window-vsync = false"))
    }

}
