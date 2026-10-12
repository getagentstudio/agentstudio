# Local telemetry without the field filter — Requirements

Specification: [2026-10-12-otlp-export-without-field-allowlist.md](2026-10-12-otlp-export-without-field-allowlist.md)

## Who is affected and what hurts

The people affected are the owner and the agents who prove Agent Studio's behavior. They read its telemetry from the local observability stack on this Mac: VictoriaLogs and VictoriaMetrics, fed by the app's loopback-only OTLP export.

Today, the app filters every log field against hand-kept lists before export. About 840 field names and value sets are allowed, and anything not on a list is silently dropped. Real losses:

- **Panes sidebar activity** loses its surface (`panes` is not an allowed value). The sidebar investigation on 2026-10-12 could not see which surface was built.
- **`sidebar.sort_order`** was dropped, which broke the title-pane verifier.
- **Real durations and counts** were dropped, for example `git.admission_to_status.elapsed_ms` and the filesystem shared-ancestor measurements.

The same filter also feeds metrics. Metrics derive samples from the filtered fields, and some carry noise: flag and sequence gauges, plus three trace-queue statistics copied onto every event's series (372 of 3,581 series).

The filter protects nothing that matters here. Export is loopback-only, enforced by the trace configuration. The local JSONL trace already holds every unfiltered field. The shared collector separately redacts token, secret, password and payload patterns.

## What the owner asked for

| ID | Need, in the owner's words | Authority | Priority |
| --- | --- | --- | --- |
| U1 | "its a local filter we dont even use it, its local otel too … get rid of it" | authorized: owner, 2026-10-11 | required (owner) |
| U2 | "check the cardinality of metrics make sure they are not slop" | authorized: owner, 2026-10-11 | required (owner) |
| U3 | The agreed shape, as one draft PR with a hard cutover. **Logs** keep every field. **Metrics** come only from an explicit list of real measurements (durations and real counts), with hand-picked labels. **Trace-queue statistics** are reported once per process, not copied onto every event series. The **observability doc and the CLAUDE.md sentence** that describe the old scrubbing are updated in the same PR. The **loopback-only export guard** and the **atoms tag opt-in** stay. | authorized: owner, 2026-10-11, recorded in the IPC lane handoff | required (owner) |
| U4 | The losses above: Panes surface, sort order, real durations, and noisy metric series | observational | — |
| U5 | Agent message text is never exported to OTLP or JSONL telemetry. This is agent IPC v2 requirement U9, which cites the CLAUDE.md scrub sentence this change rewrites. | authorized: owner, agent IPC v2 decision D4 ([user requirements](../2026-09-12-agent-ipc-v2/user-requirements.md) U9) | required (owner) |

## Boundary

- **Goal:** local logs carry every field the app records. Local metrics carry only bounded, real measurements.
- **Reuse:**
  - the existing trace runtime, JSONL sink and OTLP sink;
  - the loopback guard in the trace configuration;
  - the tag-level volume control (wildcard excludes atoms);
  - the hand-picked metric label sets;
  - the shared collector's redaction.
- **Allowed to change:**
  - the OTLP log projection, metric derivation and trace-queue reporting;
  - the tests that pin the old filtering;
  - the verifier scripts whose checks depend on it;
  - the observability doc and the CLAUDE.md sentence.
- **Protected:**
  - loopback-only export;
  - atoms staying opt-in;
  - JSONL content;
  - agent message text staying out of every telemetry record (U5), and that rule staying written in CLAUDE.md;
  - which events are recorded and when;
  - collector configuration, which is owned by the shared host and not changed here.
- **Not in this change:**
  - new events or new fields;
  - metric label changes beyond letting existing sidebar values through: `panes`, and `activity` grouping;
  - a cardinality guard mechanism;
  - dashboards (none exist on the shared host);
  - collector changes.
- **Acceptable complexity:** delete the filter. Replace metric sample selection with one explicit list. Move the queue statistics to one process-level report. No new subsystem.
- **Acceptable evidence:**
  - tests asserting logs keep every field and metrics carry only listed measurements;
  - a real debug launch exporting to the local stack;
  - a before/after series count from the local VictoriaMetrics;
  - the updated verifiers passing.
  - a marker-scoped run showing message text absent from JSONL and the log store, before and after.
