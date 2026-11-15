import AgentStudioInfrastructure
import Foundation

extension FilesystemActor {
    func recordWatchedFolderScanDemand(_ request: WatchedFolderScanRequest, submission: WatchedFolderPacingSubmission) {
        var attributes: [String: AgentStudioTraceValue] = [
            "agentstudio.performance.filesystem.watched_scan.folder_tag": .string(
                WatchedFolderScanScheduler.diagnosticTag(request.sourceID)),
            "agentstudio.performance.filesystem.watched_scan.submission_sequence": .int(
                Int(clamping: request.submissionSequence)),
            "agentstudio.performance.filesystem.watched_scan.reason": .string(
                watchedFolderDemandReason(request.cause, context: submission.context)),
        ]
        if case .obligation(let ordinal, let openedAt, let interval) = submission.context {
            attributes["agentstudio.performance.filesystem.watched_scan.obligation_ordinal"] = .int(
                Int(clamping: ordinal))
            attributes["agentstudio.performance.filesystem.watched_scan.interval_ordinal"] = .int(
                Int(clamping: interval.intervalOrdinal))
            attributes["agentstudio.performance.filesystem.watched_scan.first_trigger_offset_ms"] = .int(
                watchedScanMilliseconds(interval.firstTriggerAt - openedAt))
            attributes["agentstudio.performance.filesystem.watched_scan.last_trigger_offset_ms"] = .int(
                watchedScanMilliseconds(interval.lastTriggerAt - openedAt))
            attributes["agentstudio.performance.filesystem.watched_scan.quiet_gap_count"] = .int(interval.quietGapCount)
            attributes["agentstudio.performance.filesystem.watched_scan.folded_trigger_count"] = .int(
                interval.foldedTriggerCount)
            attributes["agentstudio.performance.filesystem.watched_scan.obligation_wait_ms"] = .int(
                watchedScanMilliseconds(submission.inFlight.reservedAt - openedAt))
        }
        performanceTraceRecorder?.record(.filesystemWatchedScanDemand, attributes: attributes)
    }

    func recordWatchedFolderScanRun(
        _ result: ScheduledWatchedFolderScanResult, closedObligation: WatchedFolderPacingObligation?
    ) {
        let metrics: RepoScannerServiceMetrics
        switch result.scannerResult {
        case .completeAuthoritative(let scan): metrics = scan.serviceMetrics
        case .partial(let scan): metrics = scan.serviceMetrics
        case .cancelled(let scan): metrics = scan.serviceMetrics
        case .failed(let scan): metrics = scan.serviceMetrics
        case .unavailable(let scan): metrics = scan.serviceMetrics
        }
        var attributes: [String: AgentStudioTraceValue] = [
            "agentstudio.performance.filesystem.watched_scan.folder_tag": .string(
                WatchedFolderScanScheduler.diagnosticTag(result.request.sourceID)),
            "agentstudio.performance.filesystem.watched_scan.submission_sequence": .int(
                Int(clamping: result.request.submissionSequence)),
            "agentstudio.performance.filesystem.watched_scan.demand_generation": .int(
                Int(clamping: result.demandCoverage.throughDemandGeneration.rawValue)),
            "agentstudio.performance.filesystem.watched_scan.scan_run_generation": .int(
                Int(clamping: result.scanRunGeneration)),
            "agentstudio.performance.filesystem.watched_scan.service_duration_ms": .int(
                watchedScanMilliseconds(metrics.traversalServiceDuration + metrics.validationServiceDuration)),
        ]
        if let closedObligation {
            attributes["agentstudio.performance.filesystem.watched_scan.obligation_ordinal"] = .int(
                Int(clamping: closedObligation.obligationOrdinal))
        }
        performanceTraceRecorder?.record(.filesystemWatchedScanRun, attributes: attributes)
        if let closedObligation { recordWatchedFolderScanClosure(result, obligation: closedObligation) }
    }

    private func recordWatchedFolderScanClosure(
        _ result: ScheduledWatchedFolderScanResult, obligation: WatchedFolderPacingObligation
    ) {
        performanceTraceRecorder?.record(
            .filesystemWatchedScanObligation,
            attributes: [
                "agentstudio.performance.filesystem.watched_scan.folder_tag": .string(
                    WatchedFolderScanScheduler.diagnosticTag(result.request.sourceID)),
                "agentstudio.performance.filesystem.watched_scan.obligation_ordinal": .int(
                    Int(clamping: obligation.obligationOrdinal)),
                "agentstudio.performance.filesystem.watched_scan.phase": .string("closed"),
                "agentstudio.performance.filesystem.watched_scan.span_ms": .int(
                    watchedScanMilliseconds(obligation.lastTriggerAt - obligation.openedAt)),
                "agentstudio.performance.filesystem.watched_scan.quiet_gap_count": .int(obligation.quietGapCount),
                "agentstudio.performance.filesystem.watched_scan.scan_run_generation": .int(
                    Int(clamping: result.scanRunGeneration)),
                "agentstudio.performance.filesystem.watched_scan.attributed_run_count": .int(
                    obligation.completedChangeDrivenRunCount),
            ])
    }

    private func watchedFolderDemandReason(_ cause: WatchedFolderScanCause, context: WatchedFolderSubmissionContext)
        -> String
    {
        switch cause {
        case .initialAdd: return "initial_add"
        case .manual: return "manual"
        case .fallback: return "fallback"
        case .callback:
            if case .obligation(_, _, let interval) = context {
                if interval.reasons.contains(.intakeCoverageLoss) { return "intake_coverage_loss" }
                if interval.reasons.contains(.nativeCoverageLoss) { return "native_coverage_loss" }
            }
            return "relevant_change"
        }
    }

    private func watchedScanMilliseconds(_ duration: Duration) -> Int {
        let milliseconds = AgentStudioPerformanceTraceRecorder.milliseconds(from: duration)
        return Int(max(Double(Int.min), min(Double(Int.max).nextDown, milliseconds)))
    }
}
