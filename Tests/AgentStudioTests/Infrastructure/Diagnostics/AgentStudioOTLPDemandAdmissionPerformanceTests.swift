import Testing

@testable import AgentStudioInfrastructure

@Suite
struct AgentStudioOTLPDemandAdmissionPerformanceTests {
    @Test(arguments: ["closed_for_undo", "private_unbounded_kind"])
    func rendererStringAdmissionSurvivesOrderedFamilyDelegation(value: String) {
        let attributeKey = "agentstudio.performance.renderer.event.kind"
        let record = AgentStudioTraceRecord(
            timeUnixNano: 129, severityText: .info, body: "performance.renderer.lifecycle",
            traceID: nil, spanID: nil, parentSpanID: nil,
            resource: ["service.name": "AgentStudio"],
            scope: .init(name: "agentstudio.performance", version: "0.1.0"),
            attributes: [attributeKey: .string(value)]
        )

        let projection = AgentStudioOTLPTraceProjection.project(record)

        #expect(
            projection.attributes[attributeKey] == (value == "closed_for_undo" ? .string(value) : nil)
        )
    }

    @Test(arguments: ["started", "finished"], ["periodic", "quit"])
    func scrollbackPassProjectsBoundedDimensionsAndMeasurements(phase: String, reason: String) throws {
        let outcomeKinds = [
            "written", "invalid_utf8", "keep_previous", "unchanged", "empty",
            "deadline_exceeded", "exceeded_ceiling", "launch_failed", "read_failed",
            "exited_nonzero", "retired", "cancelled", "write_failed",
        ]
        let prefix = "agentstudio.performance.scrollback.pass"
        var attributes: [String: AgentStudioTraceValue] = [
            "\(prefix).phase": .string(phase),
            "\(prefix).reason": .string(reason),
            "\(prefix).pane.count": .int(16),
            "\(prefix).captured.bytes": .int(4096),
            "\(prefix).written.bytes": .int(2048),
            "agentstudio.performance.elapsed_ms": .double(184.3),
            "\(prefix).private_payload": .string("must-not-export"),
            "\(prefix).outcome.private_unbounded.count": .int(999),
        ]
        for (index, kind) in outcomeKinds.enumerated() {
            attributes["\(prefix).outcome.\(kind).count"] = .int(index + 1)
        }
        let record = AgentStudioTraceRecord(
            timeUnixNano: 129, severityText: .info, body: "performance.scrollback.pass",
            traceID: nil, spanID: nil, parentSpanID: nil,
            resource: ["service.name": "AgentStudio"],
            scope: .init(name: "agentstudio.performance", version: "0.1.0"), attributes: attributes
        )

        let projection = AgentStudioOTLPTraceProjection.project(record)
        let metricEvent = try #require(AgentStudioOTLPPerformanceMetricEvent(record: projection))

        #expect(projection.attributes["\(prefix).phase"] == .string(phase))
        #expect(projection.attributes["\(prefix).reason"] == .string(reason))
        #expect(projection.attributes["\(prefix).pane.count"] == .int(16))
        #expect(projection.attributes["\(prefix).captured.bytes"] == .int(4096))
        #expect(projection.attributes["\(prefix).written.bytes"] == .int(2048))
        #expect(projection.attributes["\(prefix).private_payload"] == nil)
        #expect(projection.attributes["\(prefix).outcome.private_unbounded.count"] == nil)
        #expect(metricEvent.dimensionTuples.contains { $0 == ("phase", phase) })
        #expect(metricEvent.dimensionTuples.contains { $0 == ("reason", reason) })
        #expect(metricEvent.elapsedMilliseconds == 184.3)
        #expect(metricEvent.measurements.count == outcomeKinds.count + 4)
        for (index, kind) in outcomeKinds.enumerated() {
            #expect(projection.attributes["\(prefix).outcome.\(kind).count"] == .int(index + 1))
            #expect(
                metricEvent.measurements.contains {
                    guard case .counter(let sample) = $0 else { return false }
                    return sample.label == "agentstudio_performance_scrollback_pass_outcome_\(kind)_count"
                        && sample.value == Double(index + 1)
                }
            )
        }
        #expect(
            metricEvent.measurements.contains {
                guard case .counter(let sample) = $0 else { return false }
                return sample.label == "agentstudio_performance_scrollback_pass_pane_count" && sample.value == 16
            }
        )
        for (label, value) in [("captured", 4096.0), ("written", 2048.0)] {
            #expect(
                metricEvent.measurements.contains {
                    guard case .gauge(let sample) = $0 else { return false }
                    return sample.label == "agentstudio_performance_scrollback_pass_\(label)_bytes"
                        && sample.value == value
                }
            )
        }
    }

    @Test(arguments: ["private-unbounded-value", "/tmp/private"])
    func scrollbackPassRejectsUnboundedDimensionValues(value: String) throws {
        let record = AgentStudioTraceRecord(
            timeUnixNano: 129, severityText: .info, body: "performance.scrollback.pass",
            traceID: nil, spanID: nil, parentSpanID: nil,
            resource: ["service.name": "AgentStudio"],
            scope: .init(name: "agentstudio.performance", version: "0.1.0"),
            attributes: [
                "agentstudio.performance.scrollback.pass.phase": .string(value),
                "agentstudio.performance.scrollback.pass.reason": .string(value),
            ]
        )

        let projection = AgentStudioOTLPTraceProjection.project(record)
        let metricEvent = try #require(AgentStudioOTLPPerformanceMetricEvent(record: projection))

        #expect(projection.attributes["agentstudio.performance.scrollback.pass.phase"] == nil)
        #expect(projection.attributes["agentstudio.performance.scrollback.pass.reason"] == nil)
        #expect(metricEvent.dimensions.map(\.name) == ["event"])
    }

    @Test
    func repoExplorerStageSnapshotProjectsOnlyBoundedDimensionsAndIntervalCounter() throws {
        let validRecord = AgentStudioTraceRecord(
            timeUnixNano: 127,
            severityText: .info,
            body: "performance.repo_explorer.stage_snapshot",
            traceID: nil,
            spanID: nil,
            parentSpanID: nil,
            resource: ["service.name": "AgentStudio"],
            scope: .init(name: "agentstudio.performance", version: "0.1.0"),
            attributes: [
                "agentstudio.performance.repo_explorer.stage": .string("projection_worker"),
                "agentstudio.performance.repo_explorer.outcome": .string("published"),
                "agentstudio.performance.repo_explorer.interval.count": .int(17),
            ]
        )

        let validProjection = AgentStudioOTLPTraceProjection.project(validRecord)
        let metricEvent = try #require(AgentStudioOTLPPerformanceMetricEvent(record: validProjection))

        #expect(metricEvent.dimensionTuples.contains { $0 == ("stage", "projection_worker") })
        #expect(metricEvent.dimensionTuples.contains { $0 == ("outcome", "published") })
        #expect(
            metricEvent.measurements.contains {
                guard case .counter(let sample) = $0 else { return false }
                return sample.label == "agentstudio_performance_repo_explorer_interval_count"
                    && sample.value == 17
            }
        )

        let invalidRecord = AgentStudioTraceRecord(
            timeUnixNano: 128,
            severityText: .info,
            body: "performance.repo_explorer.stage_snapshot",
            traceID: nil,
            spanID: nil,
            parentSpanID: nil,
            resource: ["service.name": "AgentStudio"],
            scope: .init(name: "agentstudio.performance", version: "0.1.0"),
            attributes: [
                "agentstudio.performance.repo_explorer.stage": .string("private-unbounded-stage"),
                "agentstudio.performance.repo_explorer.outcome": .string("private-unbounded-outcome"),
                "agentstudio.performance.repo_explorer.interval.count": .int(1),
            ]
        )

        let invalidProjection = AgentStudioOTLPTraceProjection.project(invalidRecord)
        #expect(invalidProjection.attributes["agentstudio.performance.repo_explorer.stage"] == nil)
        #expect(invalidProjection.attributes["agentstudio.performance.repo_explorer.outcome"] == nil)
    }

    @Test
    func forgeAggregateProjectsEveryDeclaredNumericAttributeAsCounter() throws {
        let expectedCounterKeys = [
            "agentstudio.performance.forge.input.automatic.count",
            "agentstudio.performance.forge.input.manual.count",
            "agentstudio.performance.forge.input.follow_up.count",
            "agentstudio.performance.forge.admission.admitted.count",
            "agentstudio.performance.forge.admission.no_demand_rejected.count",
            "agentstudio.performance.forge.admission.missing_origin_rejected.count",
            "agentstudio.performance.forge.admission.active_request_coalesced.count",
            "agentstudio.performance.forge.admission.capacity_limited.count",
            "agentstudio.performance.forge.admission.freshness_deferred.count",
            "agentstudio.performance.forge.admission.backoff_deferred.count",
            "agentstudio.performance.forge.execution.started.count",
            "agentstudio.performance.forge.execution.automatic_without_demand_started.count",
            "agentstudio.performance.forge.explicit.admitted.count",
            "agentstudio.performance.forge.explicit.settled_completed.count",
            "agentstudio.performance.forge.explicit.settled_failed.count",
            "agentstudio.performance.forge.explicit.settled_obsolete.count",
            "agentstudio.performance.forge.explicit.settled_cancelled.count",
            "agentstudio.performance.forge.execution.completed.count",
            "agentstudio.performance.forge.execution.failed.count",
            "agentstudio.performance.forge.execution.cancelled.count",
            "agentstudio.performance.forge.execution.superseded.count",
            "agentstudio.performance.forge.validation.current.count",
            "agentstudio.performance.forge.validation.stale_generation.count",
            "agentstudio.performance.forge.validation.stale_origin.count",
            "agentstudio.performance.forge.validation.stale_scope.count",
            "agentstudio.performance.forge.publication.published.count",
            "agentstudio.performance.forge.publication.equal.count",
            "agentstudio.performance.forge.publication.invalidated.count",
            "agentstudio.performance.forge.deadline.scheduled.count",
            "agentstudio.performance.forge.deadline.rescheduled.count",
            "agentstudio.performance.forge.deadline.fired.count",
            "agentstudio.performance.forge.deadline.cancelled.count",
            "agentstudio.performance.forge.query.demanded_branch.count",
            "agentstudio.performance.forge.query.alias_batch.count",
            "agentstudio.performance.forge.query.returned_node.count",
            "agentstudio.performance.forge.query.complete_plan.count",
            "agentstudio.performance.forge.query.rejected_plan.count",
            "agentstudio.performance.forge.recovery.rate_limited.count",
            "agentstudio.performance.forge.recovery.unavailable.count",
            "agentstudio.performance.forge.recovery.recovered.count",
        ]
        var attributes: [String: AgentStudioTraceValue] = [:]
        for (index, key) in expectedCounterKeys.enumerated() {
            attributes[key] = .int(index + 1)
        }
        attributes["agentstudio.performance.forge.private_unbounded.count"] = .int(999)
        let record = AgentStudioTraceRecord(
            timeUnixNano: 129,
            severityText: .info,
            body: "performance.forge.refresh",
            traceID: nil,
            spanID: nil,
            parentSpanID: nil,
            resource: ["service.name": "AgentStudio"],
            scope: .init(name: "agentstudio.performance", version: "0.1.0"),
            attributes: attributes
        )

        let projection = AgentStudioOTLPTraceProjection.project(record)
        let metricEvent = try #require(AgentStudioOTLPPerformanceMetricEvent(record: projection))

        #expect(expectedCounterKeys.allSatisfy { projection.attributes[$0] != nil })
        #expect(projection.attributes["agentstudio.performance.forge.private_unbounded.count"] == nil)
        #expect(metricEvent.measurements.count == expectedCounterKeys.count)
        #expect(
            metricEvent.measurements.allSatisfy {
                guard case .counter = $0 else { return false }
                return true
            }
        )
    }

    @Test
    func coldActivityAndExplicitSourceMetricsStayBoundedAndTyped() throws {
        let attributes: [String: AgentStudioTraceValue] = [
            "agentstudio.performance.repository_fact_demand.activity.boundary_reclassified.count": .int(1),
            "agentstudio.performance.repository_fact_demand.activity.warm_repository.current": .int(2),
            "agentstudio.performance.repository_fact_demand.activity.unknown_repository.current": .int(7),
            "agentstudio.performance.repository_fact_demand.activity.inactive_repository.current": .int(119),
            "agentstudio.performance.repository_fact_demand.activity.unknown_worktree.current": .int(9),
            "agentstudio.performance.repository_fact_demand.unknown.background_only.current": .int(9),
            "agentstudio.performance.repository_fact_demand.unknown.remote_demand.current": .int(0),
            "agentstudio.performance.repository_fact_demand.unknown.forge_demand.current": .int(0),
            "agentstudio.performance.repository_fact_demand.pipeline.applied.count": .int(1),
            "agentstudio.performance.repository_fact_demand.pipeline.unknown_worktree.current": .int(9),
            "agentstudio.performance.repository_fact_demand.pipeline.unknown_background_only.current": .int(9),
            "agentstudio.performance.repository_fact_demand.pipeline.unknown_remote_demand.current": .int(0),
            "agentstudio.performance.repository_fact_demand.pipeline.unknown_forge_demand.current": .int(0),
            "agentstudio.performance.repository_fact_demand.inactive.remote_suppressed.current": .int(118),
        ]
        let projection = AgentStudioOTLPTraceProjection.project(
            AgentStudioTraceRecord(
                timeUnixNano: 321,
                severityText: .info,
                body: "performance.repository_fact_demand",
                traceID: nil,
                spanID: nil,
                parentSpanID: nil,
                resource: ["service.name": "AgentStudio"],
                scope: .init(name: "agentstudio.performance", version: "0.1.0"),
                attributes: attributes
            )
        )
        let event = try #require(AgentStudioOTLPPerformanceMetricEvent(record: projection))
        #expect(event.measurements.count == attributes.count)
        #expect(
            event.measurements.contains { measurement in
                guard case .counter(let sample) = measurement else { return false }
                return sample.label
                    == "agentstudio_performance_repository_fact_demand_activity_boundary_reclassified_count"
            })
        #expect(
            event.measurements.filter { measurement in
                guard case .gauge = measurement else { return false }
                return true
            }.count == 12)
    }

    @Test
    func compositeUpdateProjectsOnlyBoundedPartialSettlementTaxonomy() throws {
        let record = AgentStudioTraceRecord(
            timeUnixNano: 322,
            severityText: .info,
            body: "performance.repository_fact_update",
            traceID: nil,
            spanID: nil,
            parentSpanID: nil,
            resource: ["service.name": "AgentStudio"],
            scope: .init(name: "agentstudio.performance", version: "0.1.0"),
            attributes: [
                "agentstudio.performance.repository_update.stage": .string("settled"),
                "agentstudio.performance.repository_update.outcome": .string("partial_failure"),
                "agentstudio.performance.repository_update.applicable_source.count": .int(2),
                "agentstudio.performance.repository_update.terminal_source.count": .int(3),
                "agentstudio.performance.repository_update.private_repo_name": .string("secret"),
            ]
        )
        let projection = AgentStudioOTLPTraceProjection.project(record)
        let event = try #require(AgentStudioOTLPPerformanceMetricEvent(record: projection))

        #expect(event.dimensionTuples.contains { $0 == ("stage", "settled") })
        #expect(event.dimensionTuples.contains { $0 == ("outcome", "partial_failure") })
        #expect(projection.attributes["agentstudio.performance.repository_update.private_repo_name"] == nil)
    }

    @Test
    func repositoryDemandRemoteReferenceAndGitAggregatesProjectAsBoundedMetrics() throws {
        let events: [(String, [String: AgentStudioTraceValue], Int)] = [
            (
                "performance.repository_fact_demand",
                [
                    "agentstudio.performance.repository_fact_demand.projected.count": .int(64),
                    "agentstudio.performance.repository_fact_demand.content_equal.count": .int(63),
                    "agentstudio.performance.repository_fact_demand.delivered.count": .int(1),
                ],
                3
            ),
            (
                "performance.remote_reference.refresh",
                [
                    "agentstudio.performance.remote_reference.admission.admitted.count": .int(2),
                    "agentstudio.performance.remote_reference.publication.promoted.count": .int(2),
                    "agentstudio.performance.remote_reference.validation.obsolete.count": .int(1),
                    "agentstudio.performance.remote_reference.explicit.admitted.count": .int(1),
                    "agentstudio.performance.remote_reference.explicit.settled_completed.count": .int(1),
                ],
                5
            ),
            (
                "performance.git.aggregate",
                [
                    "agentstudio.performance.git.aggregate.admitted.count": .int(4),
                    "agentstudio.performance.git.aggregate.event_posted.count": .int(4),
                    "agentstudio.performance.git.aggregate.running.maximum": .int(2),
                ],
                3
            ),
        ]

        for (index, event) in events.enumerated() {
            let record = AgentStudioTraceRecord(
                timeUnixNano: UInt64(200 + index),
                severityText: .info,
                body: event.0,
                traceID: nil,
                spanID: nil,
                parentSpanID: nil,
                resource: ["service.name": "AgentStudio"],
                scope: .init(name: "agentstudio.performance", version: "0.1.0"),
                attributes: event.1
            )

            let projection = AgentStudioOTLPTraceProjection.project(record)
            let metricEvent = try #require(AgentStudioOTLPPerformanceMetricEvent(record: projection))

            #expect(metricEvent.measurements.count == event.2)
            #expect(projection.attributes.count >= event.1.count)
        }
    }

    @Test
    func gitContinuityAggregateProjectsFixedOutcomesAsCountersAndStateAsGauges() throws {
        let counterAttributes: [String: AgentStudioTraceValue] = [
            "agentstudio.performance.git.aggregate.continuity.baseline.prepared.count": .int(1),
            "agentstudio.performance.git.aggregate.continuity.baseline.accepted.count": .int(2),
            "agentstudio.performance.git.aggregate.continuity.baseline.rejected.count": .int(3),
            "agentstudio.performance.git.aggregate.continuity.renewed.count": .int(4),
            "agentstudio.performance.git.aggregate.continuity.mutation_invalidated.count": .int(5),
            "agentstudio.performance.git.aggregate.continuity.uncertainty.unsupported_observation.count": .int(6),
            "agentstudio.performance.git.aggregate.continuity.uncertainty.registration_missing.count": .int(7),
            "agentstudio.performance.git.aggregate.continuity.uncertainty.registration_replaced.count": .int(8),
            "agentstudio.performance.git.aggregate.continuity.uncertainty.identity_changed.count": .int(9),
            "agentstudio.performance.git.aggregate.continuity.uncertainty.mutation_observed.count": .int(10),
            "agentstudio.performance.git.aggregate.continuity.uncertainty.event_stream_uncertain.count": .int(11),
            "agentstudio.performance.git.aggregate.continuity.uncertainty.stream_start_failed.count": .int(12),
            "agentstudio.performance.git.aggregate.continuity.uncertainty.shutdown.count": .int(13),
            "agentstudio.performance.git.aggregate.continuity.fallback.admitted.count": .int(14),
            "agentstudio.performance.git.aggregate.continuity.fallback.coalesced.count": .int(15),
            "agentstudio.performance.git.aggregate.continuity.physical.fact_read_avoided.count": .int(16),
            "agentstudio.performance.git.aggregate.continuity.physical.detail_read_avoided.count": .int(17),
            "agentstudio.performance.git.aggregate.explicit.admitted.count": .int(18),
            "agentstudio.performance.git.aggregate.explicit.settled_completed.count": .int(19),
            "agentstudio.performance.git.aggregate.explicit.settled_failed.count": .int(20),
            "agentstudio.performance.git.aggregate.explicit.settled_obsolete.count": .int(21),
            "agentstudio.performance.git.aggregate.explicit.settled_cancelled.count": .int(22),
        ]
        let gaugeAttributes: [String: AgentStudioTraceValue] = [
            "agentstudio.performance.git.aggregate.continuity.authority.current": .int(18),
            "agentstudio.performance.git.aggregate.continuity.authority.oldest_checkpoint_age_ms": .double(1250),
        ]
        let record = AgentStudioTraceRecord(
            timeUnixNano: 299,
            severityText: .info,
            body: "performance.git.aggregate",
            traceID: nil,
            spanID: nil,
            parentSpanID: nil,
            resource: ["service.name": "AgentStudio"],
            scope: .init(name: "agentstudio.performance", version: "0.1.0"),
            attributes: counterAttributes.merging(gaugeAttributes) { _, right in right }
        )

        let projection = AgentStudioOTLPTraceProjection.project(record)
        let metricEvent = try #require(AgentStudioOTLPPerformanceMetricEvent(record: projection))

        #expect(counterAttributes.keys.allSatisfy { projection.attributes[$0] != nil })
        #expect(gaugeAttributes.keys.allSatisfy { projection.attributes[$0] != nil })
        #expect(metricEvent.measurements.count == counterAttributes.count + gaugeAttributes.count)
        #expect(
            metricEvent.measurements.filter {
                guard case .counter = $0 else { return false }
                return true
            }.count == counterAttributes.count
        )
        #expect(
            metricEvent.measurements.filter {
                guard case .gauge = $0 else { return false }
                return true
            }.count == gaugeAttributes.count
        )
    }

    @Test
    func remoteReferenceAndForgeCurrentSettlementFieldsProjectAsGaugesIncludingZero() throws {
        let settlementAttributesByEvent: [(String, [String: AgentStudioTraceValue])] = [
            (
                "performance.remote_reference.refresh",
                settlementAttributes(source: "remote_reference")
            ),
            (
                "performance.forge.refresh",
                settlementAttributes(source: "forge")
            ),
        ]

        for (index, event) in settlementAttributesByEvent.enumerated() {
            let record = AgentStudioTraceRecord(
                timeUnixNano: UInt64(300 + index),
                severityText: .info,
                body: event.0,
                traceID: nil,
                spanID: nil,
                parentSpanID: nil,
                resource: ["service.name": "AgentStudio"],
                scope: .init(name: "agentstudio.performance", version: "0.1.0"),
                attributes: event.1
            )

            let projection = AgentStudioOTLPTraceProjection.project(record)
            let metricEvent = try #require(AgentStudioOTLPPerformanceMetricEvent(record: projection))

            #expect(event.1.keys.allSatisfy { projection.attributes[$0] != nil })
            #expect(metricEvent.measurements.count == event.1.count)
            #expect(
                metricEvent.measurements.allSatisfy {
                    guard case .gauge(let sample) = $0 else { return false }
                    return sample.value == 0
                }
            )
        }
    }

    private func settlementAttributes(source: String) -> [String: AgentStudioTraceValue] {
        let prefix = "agentstudio.performance.\(source).settlement"
        return [
            "\(prefix).physical.active.current": .int(0),
            "\(prefix).pending.total.current": .int(0),
            "\(prefix).pending.future.current": .int(0),
            "\(prefix).pending.ready.current": .int(0),
            "\(prefix).pending.capacity.current": .int(0),
            "\(prefix).pending.active_follow_up.current": .int(0),
            "\(prefix).pending.unclassified.current": .int(0),
            "\(prefix).deadline.overdue.current": .int(0),
            "\(prefix).deadline.next_ms": .double(0),
        ]
    }
}
