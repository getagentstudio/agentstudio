import AgentStudioInfrastructure
import AgentStudioTerminal
import AppKit
import GhosttyKit

let globalPreferences = GlobalPreferencesBootstrap.load()
let traceRuntime = AgentStudioTraceRuntime.fromEnvironment(
    preferenceLayer: globalPreferences.tracePreferenceLayer
)
let startupTraceRecorder = AgentStudioStartupTraceRecorder(traceRuntime: traceRuntime)
GlobalPreferencesStartupTelemetry.recordLoaded(globalPreferences, recorder: startupTraceRecorder)
startupTraceRecorder.recordAppStartup(
    "app.process.start",
    phase: "process",
    attributes: [
        "agentstudio.command.source": .string("main")
    ]
)

GhosttyStartupEnvironment.apply(resourceRootURL: Bundle.appResourceRootURL)
let ghosttyArguments = GhosttyLaunchArguments.sanitized(CommandLine.arguments)
startupTraceRecorder.recordAppStartup(
    "app.ghostty_init.started",
    phase: "ghostty_init"
)
let ghosttyInitStatus = GhosttyLaunchArguments.withUnsafeArgv(from: ghosttyArguments) { argc, argv in
    ghostty_init(argc, argv)
}

// Initialize Ghostty library first (required before any other calls)
if ghosttyInitStatus != GHOSTTY_SUCCESS {
    startupTraceRecorder.recordAppStartup(
        "app.ghostty_init.failed",
        phase: "ghostty_init",
        outcome: "failed",
        attributes: [
            "agentstudio.ghostty.status": .int(Int(ghosttyInitStatus))
        ]
    )
    print("Fatal: ghostty_init failed")
    exit(1)
}
startupTraceRecorder.recordAppStartup(
    "app.ghostty_init.succeeded",
    phase: "ghostty_init",
    outcome: "succeeded"
)

// Create NSApplication first
let app = NSApplication.shared
startupTraceRecorder.recordAppStartup(
    "app.ns_application.created",
    phase: "ns_application"
)

// Set activation policy to make it a proper GUI app (required for CLI-launched binaries)
app.setActivationPolicy(.regular)
UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
RestoreTrace.log("main: app activation policy set, debugLogPath=\(debugLogPath)")

let delegate = AppDelegate(
    traceRuntime: traceRuntime,
    startupTraceRecorder: startupTraceRecorder
)
startupTraceRecorder.recordAppStartup(
    "app.delegate.created",
    phase: "delegate"
)
app.delegate = delegate

// Initialize Ghostty terminal engine after NSApplication exists
startupTraceRecorder.recordAppStartup(
    "app.ghostty_engine.started",
    phase: "ghostty_engine"
)
let ghosttyInitialized = delegate.initializeNativeEngineForBoot()
if !ghosttyInitialized {
    startupTraceRecorder.recordAppStartup(
        "app.ghostty_engine.failed",
        phase: "ghostty_engine",
        outcome: "failed"
    )
    print("Warning: Failed to initialize Ghostty terminal engine")
} else {
    startupTraceRecorder.recordAppStartup(
        "app.ghostty_engine.succeeded",
        phase: "ghostty_engine",
        outcome: "succeeded"
    )
    RestoreTrace.log("main: Ghostty.initialize succeeded")
}

// Activate the app to bring it to front
app.activate(ignoringOtherApps: true)

app.run()
