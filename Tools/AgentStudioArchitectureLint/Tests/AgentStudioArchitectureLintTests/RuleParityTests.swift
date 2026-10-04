import Foundation
import SwiftParser
import SwiftSyntax
import Testing

@testable import AgentStudioArchitectureLintCore

@MainActor
@Suite(.serialized)
struct RuleParityTests {
    @Test("drawer toolbar rejects raw button constructors while owned controls remain valid")
    func drawerToolbarRequiresOwnedControls() throws {
        let failures = try lintFixtureCorpus("Bad").filter { $0.ruleID == "agentstudio_drawer_toolbar_owned_controls" }
        #expect(failures.count == 3)
        #expect(try lintFixtureCorpus("Good").allSatisfy { $0.ruleID != "agentstudio_drawer_toolbar_owned_controls" })
    }

    @Test("performance guard fixtures fail all four promoted performance rules")
    func performanceGuardFixturesFailAllFourPromotedPerformanceRules() throws {
        let diagnostics = try lintFixtureCorpus("Bad")
        let performanceRuleIDs = Set(
            diagnostics.filter {
                $0.ruleID.hasPrefix("agentstudio_observation_capture_")
                    || $0.ruleID.hasPrefix("agentstudio_mainactor_unbounded_")
                    || $0.ruleID.hasPrefix("agentstudio_performance_constants_")
                    || $0.ruleID.hasPrefix("agentstudio_nonisolated_async_")
            }.map(\.ruleID)
        )

        #expect(performanceRuleIDs.count == 4)
        #expect(diagnostics.filter { performanceRuleIDs.contains($0.ruleID) }.allSatisfy { $0.severity == .error })
    }

    @Test("bad fixture corpus exercises every migrated rule")
    func badFixtureCorpusExercisesEveryMigratedRule() throws {
        let diagnostics = try lintFixtureCorpus("Bad")
        let actualIDs = Set(diagnostics.map(\.ruleID))
        let expectedIDs = Set(ExpectedRuleInventory.rules.map(\.id))

        #expect(actualIDs.isSuperset(of: expectedIDs))
    }

    @Test("dedicated-thread expectation fixtures reject unattributed issues and allow returned observations")
    func expectationsRemainOnTheTestTask() throws {
        let ruleID = "agentstudio_no_expectation_off_test_task"
        let failures = try lintFixtureCorpus("Bad").filter { $0.ruleID == ruleID }
        #expect(failures.count == 6)
        #expect(failures.allSatisfy { $0.severity == .error })
        #expect(try lintFixtureCorpus("Good").allSatisfy { $0.ruleID != ruleID })
    }

    @Test("process-wide singleton fixtures reject globals and allow values or computed projections")
    func processSingletonFixturesEnforceProductionScope() throws {
        let ruleID = "agentstudio_no_new_process_singletons"
        let failures = try lintFixtureCorpus("Bad").filter { $0.ruleID == ruleID }
        #expect(failures.count == 5)
        #expect(failures.allSatisfy { $0.severity == .error })
        #expect(try lintFixtureCorpus("Good").allSatisfy { $0.ruleID != ruleID })
    }

    @Test("good fixture corpus stays clean")
    func goodFixtureCorpusStaysClean() throws {
        let diagnostics = try lintFixtureCorpus("Good")

        #expect(diagnostics.isEmpty)
    }

    @Test("product atom boundary covers every forbidden ownership edge")
    func productAtomBoundaryCoversEveryForbiddenOwnershipEdge() throws {
        let diagnostics = try lintFixtureCorpus("Bad")
            .filter { $0.ruleID == "agentstudio_product_atom_boundary" }

        #expect(diagnostics.contains { $0.message.contains("Infrastructure must not name product atom state") })
        #expect(diagnostics.contains { $0.message.contains("Core must not name Feature-owned atom state") })
        #expect(diagnostics.contains { $0.message.contains("must not name sibling Feature atom state") })
        #expect(diagnostics.contains { $0.message.contains("KeyPath<AtomRegistry") })
        #expect(diagnostics.contains { $0.message.contains("static or global AtomRegistry") })
        #expect(diagnostics.contains { $0.message.contains("second App atom scope") })
        #expect(diagnostics.contains { $0.message.contains("runtime atom resolver") })
        #expect(diagnostics.contains { $0.message.contains("runtime atom registration") })
        #expect(diagnostics.contains { $0.message.contains("atom compatibility API") })
        #expect(diagnostics.contains { $0.message.contains("old AtomScope compatibility API") })
        #expect(diagnostics.contains { $0.message.contains("uniform Feature state root") })
        #expect(diagnostics.contains { $0.message.contains("Feature registry or ambient scope") })
        #expect(diagnostics.contains { $0.message.contains("concrete AppCommandDispatcher") })
    }

    @Test("test Core atom fallback installation has one centralized owner")
    func testCoreAtomFallbackInstallationHasOneCentralizedOwner() throws {
        let diagnostics = try lintFixtureCorpus("Bad")
            .filter { $0.ruleID == "agentstudio_test_core_atom_fallback_ownership" }

        #expect(diagnostics.count == 1)
        #expect(diagnostics.first?.message.contains("TestAtomRegistry.swift") == true)
    }

    @Test("import direction covers realized product and paired-test module boundaries")
    func importDirectionCoversRealizedProductAndPairedTestModuleBoundaries() throws {
        let diagnostics = try lintFixtureCorpus("Bad")
            .filter { $0.ruleID == "agentstudio_import_direction" }

        #expect(diagnostics.contains { $0.message.contains("Infrastructure cannot import AgentStudioCore") })
        #expect(diagnostics.contains { $0.message.contains("Core cannot import AgentStudioTerminal") })
        #expect(diagnostics.contains { $0.message.contains("Feature Terminal cannot import AgentStudioBridge") })
        #expect(diagnostics.contains { $0.message.contains("Product targets must not import AgentStudioTestSupport") })
        #expect(
            diagnostics.contains {
                $0.message.contains("Infrastructure tests must not import AgentStudioTestSupport")
            })
        #expect(
            diagnostics.contains {
                $0.message.contains("SharedComponents tests must not import AgentStudioTestSupport")
            })
        #expect(diagnostics.contains { $0.message.contains("Core tests cannot import AgentStudio") })
        #expect(diagnostics.contains { $0.message.contains("Feature Terminal tests cannot import AgentStudioBridge") })
        #expect(diagnostics.contains { $0.message.contains("TestSupport cannot import AgentStudioBridge") })
        for featureModule in [
            "AgentStudioBridge",
            "AgentStudioCodeViewer",
            "AgentStudioCommandBar",
            "AgentStudioEditorChooser",
            "AgentStudioInboxNotification",
            "AgentStudioRepoExplorer",
            "AgentStudioTerminal",
            "AgentStudioWebview",
        ] {
            #expect(
                diagnostics.contains {
                    $0.message.contains("Core cannot import \(featureModule)")
                })
        }
    }

    @Test("retired Worktrunk rule rejects service, startup phase, and production CLI fallbacks")
    func retiredWorktrunkRuleRejectsServiceStartupPhaseAndProductionCLIFallbacks() throws {
        let fixture = fixtureRoot()
            .appendingPathComponent(
                "Bad/Sources/AgentStudio/App/BadRetiredWorktrunkIntegration.swift"
            )
            .path

        let diagnostics = try lint(files: [fixture])
            .filter { $0.ruleID == "agentstudio_retired_worktrunk_cli" }

        #expect(diagnostics.contains { $0.message.contains("Worktrunk integration") })
        #expect(diagnostics.contains { $0.message.contains("production wt CLI fallback") })
        #expect(diagnostics.contains { $0.message.contains("production git CLI fallback") })
        #expect(diagnostics.contains { $0.message.contains("startup dependency phase") })
    }

    @Test("canonical atom mutation rejects writable owner storage and bindings")
    func canonicalAtomMutationRejectsWritableOwnerStorageAndBindings() throws {
        let fixture = fixtureRoot()
            .appendingPathComponent(
                "Bad/Sources/AgentStudio/Core/State/MainActor/Atoms/BadCanonicalAtomMutation.swift"
            )
            .path

        let diagnostics = try lint(files: [fixture])
            .filter { $0.ruleID == "agentstudio_canonical_atom_mutation" }

        #expect(diagnostics.map(\.line) == [2, 3, 4, 5])
        #expect(
            diagnostics.filter { $0.message.contains("private or private(set)") }.count == 3)
        #expect(diagnostics.filter { $0.message.contains("writable binding") }.count == 1)
    }

    @Test("canonical atom mutation ignores test helpers in mirrored owner folders")
    func canonicalAtomMutationIgnoresTestHelpersInMirroredOwnerFolders() {
        let diagnostics = CanonicalAtomMutationRule().validate(
            context: context(
                path:
                    "/tmp/Tests/AgentStudioTests/Core/State/MainActor/Atoms/RepositoryTopologyAtomTests.swift",
                source: """
                    private final class RepositoryTopologyObservationFlag {
                        var didFire = false
                    }
                    """
            )
        )

        #expect(diagnostics.isEmpty)
    }

    @Test("shared components reject Core-owned command icon references")
    func sharedComponentsRejectCoreOwnedCommandIconReferences() throws {
        let fixture = fixtureRoot()
            .appendingPathComponent("Bad")
            .appendingPathComponent("Sources")
            .appendingPathComponent("AgentStudio")
            .appendingPathComponent("SharedComponents")
            .appendingPathComponent("BadSharedComponentStaticRead.swift")
            .path

        let diagnostics = try lint(files: [fixture])
            .filter { diagnostic in
                diagnostic.ruleID == "agentstudio_shared_components_are_stateless"
                    && diagnostic.message.contains("Core-owned presentation types")
            }

        #expect(diagnostics.contains { $0.line == 2 })
    }

    @Test("shared components reject atom scope environment reads")
    func sharedComponentsRejectAtomScopeEnvironmentReads() throws {
        let fixture = fixtureRoot()
            .appendingPathComponent("Bad/Sources/AgentStudio/SharedComponents/BadSharedComponent.swift")
            .path

        let diagnostics = try lint(files: [fixture]).filter {
            $0.ruleID == "agentstudio_shared_components_are_stateless"
        }

        #expect(diagnostics.contains { $0.line == 8 })
    }

    @Test("forbidden architecture marker has dedicated fixture coverage")
    func forbiddenArchitectureMarkerHasDedicatedFixtureCoverage() throws {
        let markerFixture = fixtureRoot()
            .appendingPathComponent("Bad")
            .appendingPathComponent("Sources")
            .appendingPathComponent("AgentStudio")
            .appendingPathComponent("App")
            .appendingPathComponent("BadForbiddenArchitectureMarker.swift")
            .path

        let diagnostics = try lint(files: [markerFixture])

        #expect(diagnostics.map(\.ruleID) == ["agentstudio_no_forbidden_architecture_marker"])
    }

    @Test("generic clock sleep rule handles relative AgentStudio source paths")
    func genericClockSleepRuleHandlesRelativeAgentStudioSourcePaths() {
        let allowedDiagnostics = GenericClockSleepRule().validate(
            context: context(
                path: "Sources/AgentStudio/Infrastructure/Extensions/FoundationExtensions.swift",
                source: """
                    import Foundation

                    enum AsyncDelay {
                        static func clock(_ clock: any Clock<Duration>) async throws {
                            try await clock.sleep(for: .milliseconds(1))
                        }
                    }
                    """
            )
        )
        let deniedDiagnostics = GenericClockSleepRule().validate(
            context: context(
                path: "Sources/AgentStudio/App/BadGenericClockSleep.swift",
                source: """
                    import Foundation

                    func waitOnTaskSleepFor() async throws {
                        try await Task.sleep(for: .milliseconds(1))
                    }
                    """
            )
        )

        #expect(allowedDiagnostics.isEmpty)
        #expect(deniedDiagnostics.map(\.ruleID) == ["agentstudio_no_generic_clock_sleep"])
    }

    @Test("test task sleep rule diagnoses every denied fixture call shape")
    func testTaskSleepRuleDiagnosesEveryDeniedFixtureCallShape() throws {
        let taskSleepFixture = fixtureRoot()
            .appendingPathComponent("Bad")
            .appendingPathComponent("Tests")
            .appendingPathComponent("AgentStudioTests")
            .appendingPathComponent("BadTaskSleepTest.swift")
            .path

        let diagnostics = try lint(files: [taskSleepFixture])
            .filter { $0.ruleID == "agentstudio_no_task_sleep_in_tests" }

        #expect(diagnostics.map(\.line) == [5, 9, 13, 17, 23, 27, 31])
    }

    @Test("test task sleep rule scopes to workspace-relative test paths")
    func testTaskSleepRuleScopesToWorkspaceRelativeTestPaths() {
        let testDiagnostics = TestTaskSleepRule().validate(
            context: context(
                path: "Tests/AgentStudioTests/BadTaskSleepTest.swift",
                source: """
                    import Foundation

                    func waitsWithTaskSleep() async throws {
                        try await Task.sleep(nanoseconds: 1_000_000)
                    }
                    """
            )
        )
        let sourceDiagnostics = TestTaskSleepRule().validate(
            context: context(
                path: "Sources/AgentStudio/App/BadTaskSleepSource.swift",
                source: """
                    import Foundation

                    func waitsWithTaskSleep() async throws {
                        try await Task.sleep(nanoseconds: 1_000_000)
                    }
                    """
            )
        )
        let externalSourceUnderTestsParentDiagnostics = TestTaskSleepRule().validate(
            context: context(
                path: "/tmp/Tests/Project/Sources/AgentStudio/App/BadTaskSleepSource.swift",
                source: """
                    import Foundation

                    func waitsWithTaskSleep() async throws {
                        try await Task.sleep(nanoseconds: 1_000_000)
                    }
                    """
            )
        )

        #expect(testDiagnostics.map(\.ruleID) == ["agentstudio_no_task_sleep_in_tests"])
        #expect(sourceDiagnostics.isEmpty)
        #expect(externalSourceUnderTestsParentDiagnostics.isEmpty)
    }

    @Test("polling wait rule diagnoses one violation per polling loop keyword")
    func pollingWaitRuleDiagnosesOneViolationPerPollingLoopKeyword() throws {
        let pollingWaitFixture = fixtureRoot()
            .appendingPathComponent("Bad")
            .appendingPathComponent("Tests")
            .appendingPathComponent("AgentStudioTests")
            .appendingPathComponent("BadPollingWaitTest.swift")
            .path

        let diagnostics = try lint(files: [pollingWaitFixture])
            .filter { $0.ruleID == "agentstudio_no_polling_wait_in_tests" }

        #expect(diagnostics.map(\.line) == [7, 16, 25, 34, 46])
        #expect(
            diagnostics.allSatisfy {
                $0.message.contains("docs/architecture/testing/testing_architecture.md#how-a-test-may-wait")
            })
    }

    @Test("polling wait rule leaves event-driven waits and ordinary loops alone")
    func pollingWaitRuleLeavesEventDrivenWaitsAndOrdinaryLoopsAlone() throws {
        let eventDrivenFixture = fixtureRoot()
            .appendingPathComponent("Good")
            .appendingPathComponent("Tests")
            .appendingPathComponent("AgentStudioTests")
            .appendingPathComponent("GoodEventDrivenWaitTest.swift")
            .path

        let diagnostics = try lint(files: [eventDrivenFixture])
            .filter { $0.ruleID == "agentstudio_no_polling_wait_in_tests" }

        #expect(diagnostics.isEmpty)
    }

    @Test("polling wait rule scopes to test sources and reports the innermost polling loop")
    func pollingWaitRuleScopesToTestSourcesAndReportsInnermostPollingLoop() {
        let nestedLoopSource = """
            func drainsEveryPane(paneIds: [Int], isDrained: (Int) -> Bool) async {
                for paneId in paneIds {
                    while !isDrained(paneId) {
                        await Task.yield()
                    }
                }
            }
            """
        let testDiagnostics = TestPollingWaitRule().validate(
            context: context(path: "Tests/AgentStudioTests/BadNestedPollingTest.swift", source: nestedLoopSource)
        )
        let productionDiagnostics = TestPollingWaitRule().validate(
            context: context(path: "Sources/AgentStudio/App/PollingProduction.swift", source: nestedLoopSource)
        )

        #expect(testDiagnostics.map(\.line) == [3])
        #expect(productionDiagnostics.isEmpty)
    }

    @Test("polling wait rule treats Date.now and bound clock .now as clock reads")
    func pollingWaitRuleTreatsDateNowAndBoundClockNowAsClockReads() {
        let dateNowDiagnostics = TestPollingWaitRule().validate(
            context: context(
                path: "Tests/AgentStudioTests/BadDateNowPollingTest.swift",
                source: """
                    func waitsUntilDateNowDeadline(condition: () -> Bool) {
                        let deadline = Date.now.addingTimeInterval(10)
                        while Date.now < deadline {
                            if condition() {
                                return
                            }
                        }
                    }
                    """
            )
        )
        let boundClockDiagnostics = TestPollingWaitRule().validate(
            context: context(
                path: "Tests/AgentStudioTests/BadBoundClockPollingTest.swift",
                source: """
                    func waitsUntilBoundClockDeadline(condition: () -> Bool) {
                        let ticker = ContinuousClock()
                        let deadline = ticker.now.advanced(by: .seconds(10))
                        while ticker.now < deadline {
                            if condition() {
                                return
                            }
                        }
                    }
                    """
            )
        )

        #expect(dateNowDiagnostics.map(\.line) == [3])
        #expect(boundClockDiagnostics.map(\.line) == [4])
    }

    @Test("EventBus subscriber policy rule diagnoses every denied fixture call shape")
    func eventBusSubscriberPolicyRuleDiagnosesEveryDeniedFixtureCallShape() throws {
        let eventBusFixture = fixtureRoot()
            .appendingPathComponent("Bad")
            .appendingPathComponent("Sources")
            .appendingPathComponent("AgentStudio")
            .appendingPathComponent("App")
            .appendingPathComponent("BadEventBusSubscriberPolicy.swift")
            .path

        let diagnostics = try lint(files: [eventBusFixture])
            .filter { $0.ruleID == "agentstudio_eventbus_subscriber_policy_required" }

        #expect(diagnostics.count == 10)
        #expect(
            diagnostics.map(\.message).contains(
                "Production EventBus subscriber call sites must pass an explicit BusSubscriberPolicy"))
        #expect(
            diagnostics.map(\.message).contains(
                "Production EventBus subscriber call sites must use BusSubscriberPolicy, not raw AsyncStream bufferingPolicy"
            ))
        #expect(
            diagnostics.map(\.message).contains(
                "Production EventBus wait helpers must pass an explicit BusSubscriberPolicy"))
        #expect(
            diagnostics.map(\.message).contains(
                "Production EventBus subscriber helpers must not provide default policy arguments"))
        #expect(
            diagnostics.map(\.message).contains(
                "Production EventBus subscriber helpers must not hide policy behind zero-argument overloads"))
    }

    @Test("Terminal local disposition publication rule diagnoses every local disposition")
    func terminalLocalDispositionPublicationRuleDiagnosesEveryLocalDisposition() throws {
        let fixture = fixtureRoot()
            .appendingPathComponent("Bad")
            .appendingPathComponent("Sources")
            .appendingPathComponent("AgentStudio")
            .appendingPathComponent("Features")
            .appendingPathComponent("Terminal")
            .appendingPathComponent("Ghostty")
            .appendingPathComponent("BadTerminalLocalDispositionPublication.swift")
            .path

        let diagnostics = try lint(files: [fixture])
            .filter { $0.ruleID == "agentstudio_terminal_local_disposition_publication" }

        #expect(diagnostics.map(\.line) == [8, 11, 14, 17, 20])
        #expect(
            Set(diagnostics.map(\.message)) == [
                "GhosttyActionDisposition local-only cases must contract locally before routeActionToTerminalRuntimeOnMainActor"
            ])
    }

    @Test("Terminal local disposition publication rule rejects fallthrough to the semantic edge")
    func terminalLocalDispositionPublicationRuleRejectsFallthroughToSemanticEdge() throws {
        let fixture = fixtureRoot()
            .appendingPathComponent("Bad")
            .appendingPathComponent("Sources")
            .appendingPathComponent("AgentStudio")
            .appendingPathComponent("Features")
            .appendingPathComponent("Terminal")
            .appendingPathComponent("Ghostty")
            .appendingPathComponent("BadTerminalLocalDispositionFallthrough.swift")
            .path

        let diagnostics = try lint(files: [fixture])
            .filter { $0.ruleID == "agentstudio_terminal_local_disposition_publication" }

        #expect(diagnostics.map(\.line) == [9])
        #expect(
            diagnostics.map(\.message) == [
                "GhosttyActionDisposition local-only cases must end in a top-level return before semantic runtime publication"
            ])
    }

    @Test("Terminal local disposition publication rule rejects stored classifier results")
    func terminalLocalDispositionPublicationRuleRejectsStoredClassifierResults() throws {
        let fixture = fixtureRoot()
            .appendingPathComponent("Bad")
            .appendingPathComponent("Sources")
            .appendingPathComponent("AgentStudio")
            .appendingPathComponent("Features")
            .appendingPathComponent("Terminal")
            .appendingPathComponent("Ghostty")
            .appendingPathComponent("BadTerminalStoredDispositionClassification.swift")
            .path

        let diagnostics = try lint(files: [fixture])
            .filter { $0.ruleID == "agentstudio_terminal_local_disposition_publication" }

        #expect(diagnostics.map(\.line) == [3])
        #expect(
            diagnostics.map(\.message) == [
                "GhosttyActionDisposition.classify results must be consumed directly by a switch"
            ])
    }

    @Test("comparison-target query control rule rejects catalog production calls")
    func comparisonTargetQueryControlRuleRejectsCatalogProductionCalls() throws {
        let fixture = fixtureRoot()
            .appendingPathComponent("Bad")
            .appendingPathComponent("Sources")
            .appendingPathComponent("AgentStudio")
            .appendingPathComponent("Features")
            .appendingPathComponent("Bridge")
            .appendingPathComponent("Transport")
            .appendingPathComponent("BadComparisonTargetQueryControlProduction.swift")
            .path

        let diagnostics = try lint(files: [fixture])
            .filter { $0.ruleID == "agentstudio_comparison_target_query_control_production" }

        #expect(diagnostics.map(\.line) == [7, 8, 9, 10, 11, 12, 13])
        #expect(
            Set(diagnostics.map(\.message)) == [
                "Comparison-target query control must only authorize and reserve content; catalog production belongs to the content task producer"
            ])
    }

    @Test("tooltip source rule scopes raw help to migrated dense controls")
    func tooltipSourceRuleScopesRawHelpToMigratedDenseControls() {
        let migratedDiagnostics = TooltipSourceRule().validate(
            context: context(
                path: "Sources/AgentStudio/Core/Views/Drawer/DrawerIconBar.swift",
                source: """
                    import SwiftUI

                    struct DrawerIconBar: View {
                        var body: some View {
                            Button("Add") {}
                                .help("Add drawer pane")
                        }
                    }
                    """
            )
        )
        let sharedSearchDiagnostics = TooltipSourceRule().validate(
            context: context(
                path: "Sources/AgentStudio/SharedComponents/SidebarSearchField.swift",
                source: """
                    import SwiftUI

                    struct SidebarSearchField: View {
                        let clearHelp: String?
                        var body: some View {
                            Button("Clear") {}
                                .help(clearHelp ?? "")
                        }
                    }
                    """
            )
        )

        #expect(migratedDiagnostics.map(\.ruleID) == ["agentstudio_toolbar_tooltip_source"])
        #expect(sharedSearchDiagnostics.isEmpty)
    }

    @Test("tooltip source rule allows non-dense help in migrated files")
    func tooltipSourceRuleAllowsNonDenseHelpInMigratedFiles() {
        let diagnostics = TooltipSourceRule().validate(
            context: context(
                path: "Sources/AgentStudio/Core/Views/Drawer/DrawerIconBar.swift",
                source: """
                    import SwiftUI

                    struct DrawerIconBar: View {
                        var body: some View {
                            Text("Status")
                                .help("This is explanatory status help")
                        }
                    }
                    """
            )
        )

        #expect(diagnostics.isEmpty)
    }

    @Test("tooltip source rule blocks hover presenter tooltipText label")
    func tooltipSourceRuleBlocksHoverPresenterTooltipTextLabel() {
        let diagnostics = TooltipSourceRule().validate(
            context: context(
                path: "Sources/AgentStudio/Core/Views/Drawer/DrawerIconBar.swift",
                source: """
                    struct DrawerIconBar {
                        func presenter() {
                            FloatingHoverTooltipPresenter(
                                activeTarget: "add",
                                anchorFrames: [:],
                                availableWidth: 100,
                                tooltipText: { _ in "Add drawer pane" }
                            )
                        }
                    }
                    """
            )
        )

        #expect(diagnostics.map(\.ruleID) == ["agentstudio_toolbar_tooltip_source"])
    }

    @Test("tooltip source rule blocks AppKit tooltip assignment but allows reads")
    func tooltipSourceRuleBlocksAppKitTooltipAssignmentButAllowsReads() {
        let assignmentDiagnostics = TooltipSourceRule().validate(
            context: context(
                path: "Sources/AgentStudio/App/Windows/MainWindowController.swift",
                source: """
                    import AppKit

                    final class MainWindowController {
                        func configure(button: NSButton) {
                            button.toolTip = "Watch folder"
                        }
                    }
                    """
            )
        )
        let noSpaceAssignmentDiagnostics = TooltipSourceRule().validate(
            context: context(
                path: "Sources/AgentStudio/App/Windows/MainWindowController.swift",
                source: """
                    import AppKit

                    final class MainWindowController {
                        func configure(button: NSButton) {
                            button.toolTip="Watch folder"
                        }
                    }
                    """
            )
        )
        let readDiagnostics = TooltipSourceRule().validate(
            context: context(
                path: "Sources/AgentStudio/App/Windows/MainWindowController.swift",
                source: """
                    import AppKit

                    final class MainWindowController {
                        func read(button: NSButton) -> String? {
                            button.toolTip
                        }
                    }
                    """
            )
        )

        #expect(assignmentDiagnostics.map(\.ruleID) == ["agentstudio_toolbar_tooltip_source"])
        #expect(noSpaceAssignmentDiagnostics.map(\.ruleID) == ["agentstudio_toolbar_tooltip_source"])
        #expect(readDiagnostics.isEmpty)
    }

    @Test("tooltip source rule blocks command semantics from render boundaries")
    func tooltipSourceRuleBlocksCommandSemanticsFromRenderBoundaries() {
        let coreDiagnostics = TooltipSourceRule().validate(
            context: context(
                path: "Sources/AgentStudio/Core/Actions/ControlTooltipSource.swift",
                source: """
                    struct BadControlTooltipSource {
                        let commandSpec: AppCommandSpec
                        let privilegeClass: IPCPrivilegeClass
                        let executeParams: IPCCommandExecuteParams
                    }
                    """
            )
        )
        let infrastructureDiagnostics = TooltipSourceRule().validate(
            context: context(
                path: "Sources/AgentStudio/Infrastructure/ControlTooltipRenderValue.swift",
                source: """
                    struct BadControlTooltipRenderValue {
                        let commandIdentifier: IPCCommandIdentifier
                        let commandListResult: IPCCommandListResult
                    }
                    """
            )
        )
        let sharedComponentDiagnostics = TooltipSourceRule().validate(
            context: context(
                path: "Sources/AgentStudio/SharedComponents/BadTooltipComponent.swift",
                source: """
                    import SwiftUI

                    struct BadTooltipComponent: View {
                        let actionSpec: ActionSpec
                        let source: ControlTooltipSource
                        let commandIdentifier: IPCCommandIdentifier
                        let localAction: LocalActionSpec

                        var body: some View { Text("") }
                    }
                    """
            )
        )

        #expect(
            coreDiagnostics.map(\.ruleID) == [
                "agentstudio_toolbar_tooltip_source",
                "agentstudio_toolbar_tooltip_source",
                "agentstudio_toolbar_tooltip_source",
            ])
        #expect(
            infrastructureDiagnostics.map(\.ruleID) == [
                "agentstudio_toolbar_tooltip_source",
                "agentstudio_toolbar_tooltip_source",
            ])
        #expect(
            sharedComponentDiagnostics.map(\.ruleID) == [
                "agentstudio_toolbar_tooltip_source",
                "agentstudio_toolbar_tooltip_source",
                "agentstudio_toolbar_tooltip_source",
                "agentstudio_toolbar_tooltip_source",
            ])
    }

    private func lintFixtureCorpus(_ corpus: String) throws -> [ArchitectureDiagnostic] {
        try LintTestSupport.lintFixtureCorpus(corpus)
    }

    private func lint(files: [String]) throws -> [ArchitectureDiagnostic] {
        try LintTestSupport.lint(files: files)
    }

    private func context(path: String, source: String) -> ArchitectureLintContext {
        LintTestSupport.context(path: path, source: source)
    }

    private func fixtureRoot() -> URL {
        LintTestSupport.fixtureRoot()
    }
}
