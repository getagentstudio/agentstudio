import Testing

@testable import AgentStudio

struct BridgeProductPaintStartupDiagnosticTests {
    @Test("no-worktree Review startup success requires both certified no-source regions")
    func noSourceStartupRequiresBothCertifiedRegions() {
        let ready = BridgeReviewNoSourceStartupRenderProof(
            contentState: "empty", contentReason: "noSource", treeState: "empty", treeReason: "noSource")
        #expect(ready.succeeded)
        let loading = BridgeReviewNoSourceStartupRenderProof(
            contentState: "loading", contentReason: nil, treeState: "empty", treeReason: "noSource")
        #expect(!loading.succeeded)
        let otherEmpty = BridgeReviewNoSourceStartupRenderProof(
            contentState: "empty", contentReason: "noSource", treeState: "empty", treeReason: "noSelection")
        #expect(!otherEmpty.succeeded)
    }

    @Test("startup diagnostic action parses Bridge product paint correlation command")
    func parsesBridgeProductPaintCorrelationCommand() throws {
        let action = try #require(
            AgentStudioStartupDiagnosticAction.fromEnvironment([
                AgentStudioStartupDiagnosticAction.environmentKey: " bridge-product-paint-correlation "
            ]))

        #expect(action.kind == .bridgeProductPaintCorrelation)
        #expect(action.commandName == "bridgeProductPaintCorrelation")
        #expect(action.suppressesAutomaticLaunchPaneRestore)
    }

    @Test("Bridge product paint diagnostic correlates Review and File through painted DOM")
    func bridgeProductPaintDiagnosticCorrelatesReviewAndFilePaint() {
        let javaScript = AppDelegate.bridgeProductPaintCorrelationJavaScript(
            relativePath: "tracked.txt",
            sha256: "expected-sha",
            canary: "expected-canary"
        )

        #expect(javaScript.contains("data-bridge-painted-source-correlations"))
        #expect(javaScript.contains("correlation?.surface === surface"))
        #expect(javaScript.contains("correlation?.observedSha256 === expectedSha256"))
        #expect(javaScript.contains("correlation?.disposition === 'painted'"))
        #expect(javaScript.contains("correlation?.text?.includes(expectedCanary)"))
        #expect(javaScript.contains("correlation?.descriptorId"))
        #expect(javaScript.contains("correlation?.requestId"))
        #expect(javaScript.contains("correlation?.sourceIdentity"))
        #expect(javaScript.contains("Number.isSafeInteger(correlation?.sourceGeneration)"))
        #expect(javaScript.contains("correlation?.semanticItemId === correlation?.itemId"))
        #expect(javaScript.contains("correlation?.publicationId === paintedPublicationId"))
        #expect(javaScript.contains("typeof correlation?.pierreItemId === 'string'"))
        #expect(javaScript.contains("correlation.pierreItemId.length > 0"))
        #expect(javaScript.contains("correlation?.surface === 'file'"))
        #expect(
            javaScript.contains(
                "correlation?.pierreItemId === `file:${correlation?.itemId}`"
            ))
        #expect(javaScript.contains("correlation?.pierreItemId === correlation?.itemId"))
        #expect(javaScript.contains("pierreIdentityMatches"))
        #expect(javaScript.contains("correlation?.itemId === selectedItemId"))
        #expect(javaScript.contains("correlation?.position === 'whole'"))
        #expect(javaScript.contains("data-selected-item-id"))
        #expect(javaScript.contains("data-worktree-rendered-item-id"))
        #expect(javaScript.contains("bridge-viewer-context-file"))
        #expect(javaScript.contains("data-item-path"))
        #expect(javaScript.contains("__bridgeFrameLivenessProbe?.rafAlive"))
        #expect(javaScript.contains("paintedElementCount"))
        #expect(javaScript.contains("decodedSourceCorrelationCount"))
        #expect(javaScript.contains("reviewSurfaceRoleCandidateCount"))
        #expect(javaScript.contains("reviewIdentityCandidateCount"))
        #expect(javaScript.contains("reviewSelectedItemCandidateCount"))
        #expect(javaScript.contains("reviewWholePositionCandidateCount"))
        #expect(javaScript.contains("reviewDigestCandidateCount"))
        #expect(javaScript.contains("reviewPaintedDispositionCandidateCount"))
        #expect(javaScript.contains("reviewCanaryCandidateCount"))
        #expect(javaScript.contains("activeViewerModeIsReview"))
        #expect(javaScript.contains("reviewMetadataItemCount"))
        #expect(javaScript.contains("reviewShellPresent"))
        #expect(javaScript.contains("reviewSelectedItemPresent"))
        #expect(javaScript.contains("reviewSelectedPathPresent"))
        #expect(javaScript.contains("globalThis.__bridgeReviewSelectionDiagnostic"))
        #expect(javaScript.contains("initialSelectionRequestedCount"))
        #expect(javaScript.contains("initialSelectionSchedulingAcceptedCount"))
        #expect(javaScript.contains("selectionScheduledCount"))
        #expect(javaScript.contains("selectionFirstFrameReachedCount"))
        #expect(javaScript.contains("selectionSecondFrameReachedCount"))
        #expect(javaScript.contains("selectionSubmittedCount"))
        #expect(javaScript.contains("selectionDroppedCount"))
    }

    @Test("Review identity-chain diagnostic is independent of the full painted-source match")
    func reviewIdentityChainDiagnosticUsesIdentityCandidates() throws {
        let javaScript = AppDelegate.bridgeProductPaintCorrelationJavaScript(
            relativePath: "tracked.txt",
            sha256: "expected-sha",
            canary: "expected-canary"
        )
        let assignmentStart = try #require(
            javaScript.range(of: "const reviewIdentityChainMatched =")
        )
        let assignmentEnd = try #require(
            javaScript.range(
                of: "const reviewPaintedSourceMatchCount =",
                range: assignmentStart.upperBound..<javaScript.endIndex
            )
        )
        let assignment = javaScript[assignmentStart.lowerBound..<assignmentEnd.lowerBound]

        #expect(assignment.contains("reviewIdentityCandidateCount > 0"))
        #expect(!assignment.contains("reviewMatches"))
        #expect(!assignment.contains("expectedCanary"))
    }

    @Test("Bridge product paint diagnostic preserves adjacent rendered text nodes")
    func bridgeProductPaintDiagnosticPreservesAdjacentRenderedTextNodes() {
        let javaScript = AppDelegate.bridgeProductPaintCorrelationJavaScript(
            relativePath: "tracked.txt",
            sha256: "expected-sha",
            canary: "expected-canary"
        )

        #expect(javaScript.contains("return parts.join('');"))
        #expect(!javaScript.contains("return parts.join(' ');"))
    }

    @Test("Bridge product paint diagnostic scopes retained Review correlation work to the File host")
    func bridgeProductPaintDiagnosticScopesRetainedReviewCorrelationToFileHost() throws {
        // Arrange / Act
        let javaScript = AppDelegate.bridgeProductPaintCorrelationJavaScript(
            relativePath: "tracked.txt",
            sha256: "expected-sha",
            canary: "expected-canary"
        )
        let fileShellDeclaration = try #require(
            javaScript.range(
                of: "const fileShell = document.querySelector('[data-testid=\"bridge-file-viewer-shell\"]');"
            )
        )
        let correlationRootAssignment = try #require(
            javaScript.range(
                of: "const paintedCorrelationRoot =",
                range: fileShellDeclaration.upperBound..<javaScript.endIndex
            )
        )
        let correlationCollection = try #require(
            javaScript.range(
                of: "collectPainted(paintedCorrelationRoot);",
                range: correlationRootAssignment.upperBound..<javaScript.endIndex
            )
        )
        let phaseLocalCollection =
            javaScript[correlationRootAssignment.lowerBound..<correlationCollection.upperBound]
        let fileSelectionActivation = try #require(
            javaScript.range(
                of: "if (",
                range: correlationCollection.upperBound..<javaScript.endIndex
            )
        )
        let fileSelectionActivationEnd = try #require(
            javaScript.range(
                of: "const fileIdentityChainMatched =",
                range: fileSelectionActivation.upperBound..<javaScript.endIndex
            )
        )
        let fileSelectionBranch =
            javaScript[fileSelectionActivation.lowerBound..<fileSelectionActivationEnd.lowerBound]

        // Assert
        #expect(
            phaseLocalCollection.contains(
                "    prior.reviewPaintedSourceMatched === true && fileShell !== null\n"
                    + "      ? fileShell\n"
                    + "      : document"
            ))
        #expect(!phaseLocalCollection.contains("collectPainted(document)"))
        #expect(fileSelectionBranch.contains("queryOpenRoots(fileShell, selector)"))
        #expect(!fileSelectionBranch.contains("queryOpenRoots(document, selector)"))
    }

    @Test("Bridge product paint diagnostic activates matching File selection after File viewer commit exactly once")
    func bridgeProductPaintDiagnosticActivatesMatchingFileSelectionAfterFileViewerCommitExactlyOnce() throws {
        // Arrange / Act
        let javaScript = AppDelegate.bridgeProductPaintCorrelationJavaScript(
            relativePath: "tracked.txt",
            sha256: "expected-sha",
            canary: "expected-canary"
        )
        let activationAssignmentRange = try #require(
            javaScript.range(of: "fileSelectionActivationAttempted = true;")
        )
        let activationAttemptStateRange = try #require(
            javaScript.range(of: "let fileSelectionActivationAttempted =")
        )
        let activationGuardRange = try #require(
            javaScript.range(
                of: "if (",
                range: activationAttemptStateRange.upperBound..<activationAssignmentRange.lowerBound
            )
        )
        let activationGuard = javaScript[activationGuardRange.lowerBound..<activationAssignmentRange.lowerBound]

        // Assert
        #expect(javaScript.contains(#"button[data-item-type="file"][data-item-path="${CSS.escape(relativePath)}"]"#))
        #expect(
            javaScript.contains(
                #"[data-type="item"][data-item-type="file"][data-item-path="${CSS.escape(relativePath)}"]"#))
        #expect(javaScript.contains("const fileViewerIsActive ="))
        #expect(javaScript.contains("fileShell?.getAttribute('data-file-viewer-active') === 'true'"))
        #expect(activationGuard.contains("reviewPaintedSourceMatched"))
        #expect(activationGuard.contains("fileViewerIsActive"))
        #expect(activationGuard.contains("!filePaintedSourceMatched"))
        #expect(activationGuard.contains("!fileSelectionActivationAttempted"))
        #expect(javaScript.contains("fileSelectionActivationAttempted = true;"))
        #expect(
            javaScript.components(separatedBy: "fileSelectionActivationAttempted = true;").count == 2
        )
        #expect(
            javaScript.contains(
                "fileSelectedPathMatched,\n    fileSelectionActivationAttempted"
            ))
        #expect(!javaScript.contains("fileSelectedPath !== relativePath"))
    }

    @Test("Bridge product paint diagnostic exports scrub-safe File transition disposition")
    func bridgeProductPaintDiagnosticExportsScrubSafeFileTransitionDisposition() throws {
        // Arrange / Act
        let javaScript = AppDelegate.bridgeProductPaintCorrelationJavaScript(
            relativePath: "tracked.txt",
            sha256: "expected-sha",
            canary: "expected-canary"
        )
        let source = try String(
            contentsOfFile:
                "Sources/AgentStudio/App/Boot/AppDelegate+BridgeProductPaintCorrelationStartupDiagnostics.swift",
            encoding: .utf8
        )

        // Assert
        for field in [
            "fileModeSendAttemptCount",
            "fileModeSendSynchronousFailureCount",
            "latestFileModeDispatchDisposition",
            "latestFileSelectDispatchDisposition",
            "latestFileSelectLifecycleState",
            "latestReviewSelectDispatchDisposition",
            "latestReviewSelectLifecycleState",
            "nativeBootstrapInstallAcceptedCount",
            "nativeBootstrapInstallAttemptCount",
            "nativeBootstrapInstallCount",
            "nativeBootstrapInstallRejectedCount",
            "queuedCommandCount",
            "replacementRequestCount",
            "sessionState",
            "pageReadyState",
        ] {
            #expect(javaScript.contains(field))
        }
        for attribute in [
            "page_ready.state",
            "file_mode.send_attempt.count",
            "file_mode.send_synchronous_failure.count",
            "file_mode.latest_dispatch_disposition",
            "file_selection.latest_dispatch_disposition",
            "file_selection.latest_lifecycle_state",
            "review_selection.latest_dispatch_disposition",
            "review_selection.latest_lifecycle_state",
            "comm_session.state",
            "comm_session.queued_command.count",
            "comm_session.replacement_request.count",
            "comm_session.native_bootstrap_install.count",
            "runtime.native_bootstrap_install.attempt.count",
            "runtime.native_bootstrap_install.accepted.count",
            "runtime.native_bootstrap_install.rejected.count",
        ] {
            #expect(source.contains(attribute))
        }
        #expect(javaScript.contains("['awaiting', 'ready', 'failed']"))
        #expect(javaScript.contains("['dropped_detached', 'queued_not_ready', 'posted']"))
        #expect(javaScript.contains("['not_sent', 'dropped_detached', 'queued_not_ready', 'posted']"))
        #expect(javaScript.contains("['not_sent', 'pending', 'acked', 'failed', 'timed_out', 'superseded']"))
        #expect(!javaScript.contains("requestId:"))
        #expect(!javaScript.contains("paneId:"))
    }

    @Test("Bridge product paint diagnostic keeps one absolute readiness deadline")
    func bridgeProductPaintDiagnosticKeepsOneAbsoluteReadinessDeadline() throws {
        // Arrange
        let source = try String(
            contentsOfFile:
                "Sources/AgentStudio/App/Boot/AppDelegate+BridgeProductPaintCorrelationStartupDiagnostics.swift",
            encoding: .utf8
        )
        let diagnosticStart = try #require(
            source.range(of: "func runBridgeProductPaintCorrelationDiagnostic(")
        )
        let diagnosticEnd = try #require(
            source.range(
                of: "\n        private func ",
                range: diagnosticStart.upperBound..<source.endIndex
            )
        )
        let diagnostic = source[diagnosticStart.lowerBound..<diagnosticEnd.lowerBound]

        // Act
        let initialDeadline = try #require(diagnostic.range(of: "let initialDeadline ="))
        let initialCorrelationWait = try #require(
            diagnostic.range(
                of: "let initialProof = await waitForBridgeProductPaintCorrelation(",
                range: initialDeadline.upperBound..<diagnostic.endIndex
            )
        )
        let initialCorrelationWaitEnd = try #require(
            diagnostic.range(
                of: ")",
                range: initialCorrelationWait.upperBound..<diagnostic.endIndex
            )
        )
        let initialCorrelationWaitCall = diagnostic[
            initialCorrelationWait.lowerBound..<initialCorrelationWaitEnd.upperBound
        ]
        let normalizedInitialDeadlineSetup = diagnostic[
            initialDeadline.lowerBound..<initialCorrelationWait.lowerBound
        ].filter { !$0.isWhitespace }
        let waitFunctionStart = try #require(
            source.range(of: "private func waitForBridgeProductPaintCorrelation(")
        )
        let waitFunctionEnd = try #require(
            source.range(
                of: "private func bridgeProductPaintCorrelationProof(",
                range: waitFunctionStart.upperBound..<source.endIndex
            )
        )
        let waitFunction = source[waitFunctionStart.lowerBound..<waitFunctionEnd.lowerBound]

        // Assert
        #expect(diagnostic.components(separatedBy: "let initialDeadline =").count == 2)
        #expect(initialDeadline.lowerBound < initialCorrelationWait.lowerBound)
        #expect(
            normalizedInitialDeadlineSetup.contains(
                "letinitialDeadline=ContinuousClock.now+AppPolicies.StartupDiagnostic.bridgeFileViewSmokeReadinessTimeout"
            ))
        #expect(initialCorrelationWaitCall.contains("deadline: initialDeadline"))
        #expect(waitFunction.contains("deadline"))
        #expect(waitFunction.contains("while !proof.surfaceCorrelationSucceeded"))
        #expect(waitFunction.contains("ContinuousClock.now < deadline"))
        #expect(!waitFunction.contains("let start = ContinuousClock.now"))
        #expect(!waitFunction.contains("try? await Task.sleep"))
        #expect(!waitFunction.contains("didEnterFileReadinessPhase"))
        #expect(!waitFunction.contains("readinessPhaseStart"))
        #expect(!waitFunction.contains("AppPolicies.StartupDiagnostic.bridgeFileViewSmokeReadinessTimeout"))
    }

    @Test("Bridge product paint diagnostic reloads and proves worker replacement replay")
    func bridgeProductPaintDiagnosticReloadsAndProvesWorkerReplacementReplay() throws {
        // Arrange
        let source = try String(
            contentsOfFile:
                "Sources/AgentStudio/App/Boot/AppDelegate+BridgeProductPaintCorrelationStartupDiagnostics.swift",
            encoding: .utf8
        )
        let diagnosticStart = try #require(
            source.range(of: "func runBridgeProductPaintCorrelationDiagnostic(")
        )
        let diagnosticEnd = try #require(
            source.range(
                of: "\n        private func ",
                range: diagnosticStart.upperBound..<source.endIndex
            )
        )
        let diagnostic = source[diagnosticStart.lowerBound..<diagnosticEnd.lowerBound]

        // Act
        let replayDeadline = try #require(diagnostic.range(of: "let replayDeadline ="))
        let loadApp = try #require(
            diagnostic.range(
                of: "let reloadNavigationEvents = bridgeView.controller.loadApp()",
                range: replayDeadline.upperBound..<diagnostic.endIndex
            )
        )
        let navigationFinishedGate = try #require(
            diagnostic.range(
                of: "await waitForBridgeProductPaintNavigationFinished(",
                range: loadApp.upperBound..<diagnostic.endIndex
            )
        )
        let workerReplacementGate = try #require(
            diagnostic.range(
                of: "await waitForBridgeProductPaintWorkerReplacement(",
                range: navigationFinishedGate.upperBound..<diagnostic.endIndex
            )
        )
        let reviewRequest = try #require(
            diagnostic.range(
                of: "bridgeView.controller.requestViewerSurface(.review)",
                range: workerReplacementGate.upperBound..<diagnostic.endIndex
            )
        )
        let replayCorrelationWait = try #require(
            diagnostic.range(
                of: "let replayProof = await waitForBridgeProductPaintCorrelation(",
                range: reviewRequest.upperBound..<diagnostic.endIndex
            )
        )
        let resultRecording = try #require(
            diagnostic.range(
                of: "recordBridgeProductPaintCorrelationResult(",
                range: replayCorrelationWait.upperBound..<diagnostic.endIndex
            )
        )
        let replaySetup = diagnostic[replayDeadline.lowerBound..<navigationFinishedGate.lowerBound]
        let navigationFinishedGateCall = diagnostic[
            navigationFinishedGate.lowerBound..<workerReplacementGate.lowerBound
        ]
        let workerReplacementGateCall = diagnostic[
            workerReplacementGate.lowerBound..<reviewRequest.lowerBound
        ]
        let replayCorrelationWaitCall = diagnostic[
            replayCorrelationWait.lowerBound..<resultRecording.lowerBound
        ]
        let normalizedReplaySetup = replaySetup.filter { !$0.isWhitespace }

        // Assert
        #expect(diagnostic.components(separatedBy: "let replayDeadline =").count == 2)
        #expect(replayDeadline.lowerBound < loadApp.lowerBound)
        #expect(loadApp.lowerBound < navigationFinishedGate.lowerBound)
        #expect(navigationFinishedGate.lowerBound < workerReplacementGate.lowerBound)
        #expect(workerReplacementGate.lowerBound < reviewRequest.lowerBound)
        #expect(reviewRequest.lowerBound < replayCorrelationWait.lowerBound)
        #expect(
            normalizedReplaySetup.contains(
                "letreplayDeadline=ContinuousClock.now+AppPolicies.StartupDiagnostic.bridgeFileViewSmokeReadinessTimeout"
                    + "letreloadNavigationEvents=bridgeView.controller.loadApp()"
            ))
        #expect(navigationFinishedGateCall.contains("navigationEvents: reloadNavigationEvents"))
        #expect(navigationFinishedGateCall.contains("deadline: replayDeadline"))
        #expect(workerReplacementGateCall.contains("excluding: initialWorkerInstanceId"))
        #expect(workerReplacementGateCall.contains("deadline: replayDeadline"))
        #expect(replayCorrelationWaitCall.contains("deadline: replayDeadline"))
        #expect(source.contains("reload_replay_succeeded"))
        #expect(source.contains("worker_replacement_observed"))
    }

    @Test("Bridge product paint replay helpers share one absolute deadline")
    func bridgeProductPaintReplayHelpersShareOneAbsoluteDeadline() throws {
        // Arrange
        let source = try String(
            contentsOfFile:
                "Sources/AgentStudio/App/Boot/AppDelegate+BridgeProductPaintCorrelationStartupDiagnostics.swift",
            encoding: .utf8
        )

        // Act
        let navigationFinishedHelperStart = try #require(
            source.range(of: "private func waitForBridgeProductPaintNavigationFinished(")
        )
        let workerReplacementHelperStart = try #require(
            source.range(
                of: "private func waitForBridgeProductPaintWorkerReplacement(",
                range: navigationFinishedHelperStart.upperBound..<source.endIndex
            )
        )
        let navigationFinishedHelper = source[
            navigationFinishedHelperStart.lowerBound..<workerReplacementHelperStart.lowerBound
        ]
        let workerReplacementHelperEnd = try #require(
            source.range(
                of: "private func waitForBridgeProductPaintCorrelation(",
                range: workerReplacementHelperStart.upperBound..<source.endIndex
            )
        )
        let workerReplacementHelper = source[
            workerReplacementHelperStart.lowerBound..<workerReplacementHelperEnd.lowerBound
        ]
        let correlationHelperEnd = try #require(
            source.range(
                of: "private func bridgeProductPaintCorrelationProof(",
                range: workerReplacementHelperEnd.upperBound..<source.endIndex
            )
        )
        let correlationHelper = source[
            workerReplacementHelperEnd.lowerBound..<correlationHelperEnd.lowerBound
        ]
        let normalizedNavigationHelper = navigationFinishedHelper.filter { !$0.isWhitespace }
        let normalizedWorkerReplacementHelper = workerReplacementHelper.filter { !$0.isWhitespace }
        let normalizedCorrelationHelper = correlationHelper.filter { !$0.isWhitespace }

        // Assert
        #expect(navigationFinishedHelper.contains("deadline"))
        #expect(normalizedNavigationHelper.contains("fortryawaitnavigationEventinnavigationEvents"))
        #expect(normalizedNavigationHelper.contains(".finished"))
        #expect(
            normalizedNavigationHelper.contains("withTaskGroup")
                || normalizedNavigationHelper.contains("withThrowingTaskGroup")
        )
        #expect(normalizedNavigationHelper.contains("sleep(until:deadline"))
        #expect(normalizedNavigationHelper.contains("group.cancelAll()"))
        #expect(!navigationFinishedHelper.contains("page.isLoading"))
        #expect(workerReplacementHelper.contains("excluding initialWorkerInstanceId"))
        #expect(workerReplacementHelper.contains("deadline"))
        #expect(workerReplacementHelper.contains("activeBootstrap()?.workerInstanceId"))
        #expect(workerReplacementHelper.contains("!= initialWorkerInstanceId"))
        #expect(correlationHelper.contains("deadline"))
        for helper in [navigationFinishedHelper, workerReplacementHelper, correlationHelper] {
            #expect(!helper.contains("ContinuousClock.now +"))
            #expect(
                !helper.contains(
                    "AppPolicies.StartupDiagnostic.bridgeFileViewSmokeReadinessTimeout"
                ))
            #expect(!helper.contains("let start = ContinuousClock.now"))
        }
        #expect(!workerReplacementHelper.contains("try? await Task.sleep"))
        #expect(normalizedWorkerReplacementHelper.contains("catch{returnnil}"))
        #expect(!correlationHelper.contains("try? await Task.sleep"))
        #expect(normalizedCorrelationHelper.contains("catch{returnproof}"))
    }

    @Test("Bridge product paint diagnostic focuses before the correlated paint wait")
    func bridgeProductPaintDiagnosticFocusesBeforeCorrelatedPaintWait() throws {
        let source = try String(
            contentsOfFile:
                "Sources/AgentStudio/App/Boot/AppDelegate+BridgeProductPaintCorrelationStartupDiagnostics.swift",
            encoding: .utf8
        )
        let focusRange = try #require(
            source.range(
                of: "paneTabViewController()?.execute(.focusPane, target: pane.id, targetType: .pane)"
            )
        )
        let correlationRange = try #require(
            source.range(of: "let initialProof = await waitForBridgeProductPaintCorrelation(")
        )

        #expect(focusRange.lowerBound < correlationRange.lowerBound)
        #expect(!source.contains("waitForBridgeProductPaintHostVisibility"))
        #expect(source.contains("snapshot.documentVisibilityState == \"visible\""))
        #expect(source.contains("documentVisibilityState: document.visibilityState"))
    }

    @Test("Bridge product paint diagnostic presents through canonical window lifecycle owner")
    func bridgeProductPaintDiagnosticPresentsThroughCanonicalWindowLifecycleOwner() throws {
        // Arrange
        let source = try String(
            contentsOfFile:
                "Sources/AgentStudio/App/Boot/AppDelegate+BridgeProductPaintCorrelationStartupDiagnostics.swift",
            encoding: .utf8
        )
        let diagnosticStart = try #require(
            source.range(of: "func runBridgeProductPaintCorrelationDiagnostic(")
        )
        let diagnosticEnd = try #require(
            source.range(
                of: "\n        private func ",
                range: diagnosticStart.upperBound..<source.endIndex
            )
        )
        let diagnostic = source[diagnosticStart.lowerBound..<diagnosticEnd.lowerBound]

        // Act
        let canonicalPresentation = try #require(
            diagnostic.range(of: "mainWindowController?.completeLaunchPresentation()")
        )
        let activationWait = try #require(
            diagnostic.range(of: "await waitForStartupDiagnosticAppActivation()")
        )

        // Assert
        #expect(canonicalPresentation.lowerBound < activationWait.lowerBound)
        #expect(!diagnostic.contains("mainWindowController?.window?.makeKeyAndOrderFront(nil)"))
    }

}
