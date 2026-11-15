import Foundation
import Testing

@Suite("Observability TCC probe launcher scripts")
struct ObservabilityTCCProbeLauncherScriptsTests {
    @Test("debug and beta launchers pass through bounded TCC probe monitor knobs")
    func launchersPassThroughBoundedTCCProbeMonitorKnobs() throws {
        let debugScript = try String(contentsOfFile: "scripts/run-debug-observability.sh", encoding: .utf8)
        let betaScript = try String(contentsOfFile: "scripts/run-beta-observability.sh", encoding: .utf8)
        let debugVerifier = try String(contentsOfFile: "scripts/verify-debug-observability.sh", encoding: .utf8)
        let betaVerifier = try String(contentsOfFile: "scripts/verify-beta-observability.sh", encoding: .utf8)

        for script in [debugScript, betaScript] {
            #expect(script.contains("AGENTSTUDIO_TCC_UPGRADE_PROBE_REPEAT_COUNT"))
            #expect(script.contains("AGENTSTUDIO_TCC_UPGRADE_PROBE_INTERVAL_SECONDS"))
            #expect(script.contains("AGENTSTUDIO_OBSERVABILITY_TCC_PROBE_REPEAT_COUNT"))
            #expect(script.contains("AGENTSTUDIO_OBSERVABILITY_TCC_PROBE_INTERVAL_SECONDS"))
        }

        for verifier in [debugVerifier, betaVerifier] {
            #expect(verifier.contains("agentstudio.tcc.probe.sequence"))
            #expect(verifier.contains("_msg\" \"terminal.tcc.access_probe"))
            #expect(verifier.contains("_msg\" \"terminal.tcc.app_identity_snapshot"))
            #expect(verifier.contains("agentstudio.tcc.bundle.executable.reachable"))
        }
    }
}
