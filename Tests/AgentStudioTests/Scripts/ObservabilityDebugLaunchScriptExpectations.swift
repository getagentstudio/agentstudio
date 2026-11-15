import Foundation
import Testing

#if canImport(Darwin)
    import Darwin
#endif

func launchServicesDiagnosticEnvironment(
    fixture: LauncherScriptFixture,
    openArgsURL: URL,
    launchedAppURL: URL,
    stateFile: URL
) throws -> [String: String] {
    [
        "AGENTSTUDIO_OPEN_BIN": try fixture.executable(
            "open",
            """
            #!/bin/bash
            printf "%s\\n" "$@" > "\(openArgsURL.path)"
            for arg in "$@"; do
              case "$arg" in
                *.app)
                  printf "%s\\n" "$arg" > "\(launchedAppURL.path)"
                  ;;
              esac
            done
            exit 0
            """
        ).path,
        "AGENTSTUDIO_PGREP_BIN": try fixture.executable(
            "pgrep",
            """
            #!/bin/bash
            if [ -f "\(launchedAppURL.path)" ]; then
              echo 42424
              exit 0
            fi
            exit 1
            """
        ).path,
        "AGENTSTUDIO_LSOF_BIN": try fixture.executable(
            "lsof",
            """
            #!/bin/bash
            app_path="$(cat "\(launchedAppURL.path)")"
            printf "p42424\\nftxt\\nn%s/Contents/MacOS/AgentStudio\\n" "$app_path"
            """
        ).path,
        "AGENTSTUDIO_DITTO_BIN": try fixture.executable(
            "ditto",
            """
            #!/bin/bash
            cp -R "$1" "$2"
            """
        ).path,
        "AGENTSTUDIO_CODESIGN_BIN": try fixture.executable(
            "codesign",
            """
            #!/bin/bash
            exit 0
            """
        ).path,
        "AGENTSTUDIO_OBSERVABILITY_STATE_FILE": stateFile.path,
        "AGENTSTUDIO_RESTORE_TRACE": "1",
        "AGENTSTUDIO_STARTUP_DIAGNOSTIC_ACTION": "cross-tab-move-geometry-smoke",
        "AGENTSTUDIO_STARTUP_WATCH_FOLDER": fixture.url("watch-folder").path,
        "AGENTSTUDIO_IPC_UNSAFE_NO_AUTH": "1",
        "AGENTSTUDIO_IPC_DEBUG_TOKEN_ESCROW": try fixture.makeDebugEscrow().path,
    ]
}

func expectDirectExecutableFallbackState(_ state: String, buildExecutable: URL, hostileDataRoot: URL) throws {
    #expect(state.contains("AGENTSTUDIO_OBSERVABILITY_STATUS=running"))
    #expect(state.contains("AGENTSTUDIO_OBSERVABILITY_LAUNCH_METHOD=direct_executable"))
    #expect(state.contains("AGENTSTUDIO_OBSERVABILITY_EXECUTABLE="))
    #expect(state.contains("AgentStudio\\ Debug\\ "))
    #expect(state.contains("/runs/debug-observability-"))
    #expect(!state.contains("AGENTSTUDIO_OBSERVABILITY_EXECUTABLE=\(shellEscapedStateValue(buildExecutable.path))"))
    #expect(state.contains("AGENTSTUDIO_OBSERVABILITY_DATA_DIR="))
    #expect(state.contains("AGENTSTUDIO_OBSERVABILITY_ZMX_DIR="))
    #expect(state.contains("AGENTSTUDIO_OBSERVABILITY_STARTUP_DIAGNOSTIC_ACTION=cross-tab-move-geometry-smoke"))
    #expect(state.contains("AGENTSTUDIO_OBSERVABILITY_STARTUP_WATCH_FOLDER="))
    #expect(!state.contains(hostileDataRoot.path))
    try expectOwnerOnlyDirectory(stateValue("AGENTSTUDIO_OBSERVABILITY_DATA_DIR", in: state))
    try expectOwnerOnlyDirectory(stateValue("AGENTSTUDIO_OBSERVABILITY_ZMX_DIR", in: state))
}

func expectDirectExecutableFallbackLaunchEnvironment(
    _ launchedEnv: String, hostileDataRoot: URL, escrowPath: String
) throws {
    #expect(launchedEnv.contains("data=/"))
    #expect(launchedEnv.contains("ipc_socket_dir=/"))
    #expect(launchedEnv.contains("zmx_path=/"))
    #expect(launchedEnv.contains("/bin/zmx"))
    #expect(launchedEnv.contains("/ipc-socket"))
    #expect(launchedEnv.contains("/runs/debug-observability-"))
    #expect(launchedEnv.contains("ghostty_disable_default_config=1") && launchedEnv.contains("ghostty_disable_vsync=1"))
    #expect(launchedEnv.contains("backend=otlp"))
    #expect(launchedEnv.contains("marker=debug-observability-"))
    #expect(launchedEnv.contains("restore_trace=1"))
    #expect(launchedEnv.contains("diagnostic=cross-tab-move-geometry-smoke"))
    #expect(launchedEnv.contains("watch_folder="))
    #expect(launchedEnv.contains("ipc_no_auth=1"))
    #expect(stateValue("ipc_escrow", in: launchedEnv) == escrowPath)
    #expect(!launchedEnv.contains(hostileDataRoot.path))
    try expectOwnerOnlyDirectory(stateValue("ipc_socket_dir", in: launchedEnv))
}

func stateValue(_ key: String, in state: String) -> String {
    state.split(separator: "\n")
        .first { $0.hasPrefix("\(key)=") }
        .map { String($0.dropFirst(key.count + 1)).replacingOccurrences(of: "\\ ", with: " ") } ?? ""
}

func expectOwnerOnlyDirectory(_ rawPath: String) throws {
    var statBuffer = stat()
    #expect(!rawPath.isEmpty)
    #expect(lstat(rawPath, &statBuffer) == 0)
    #expect((statBuffer.st_mode & S_IFMT) == S_IFDIR)
    #expect((statBuffer.st_mode & 0o077) == 0)
}
