# Local telemetry without the field filter — Specification

Requirements: [requirements](2026-10-12-otlp-export-without-field-allowlist-requirements.md) (U1–U4) → this Specification → Program Design: [program design](2026-10-12-otlp-export-without-field-allowlist-program-design.md)

```mermaid
flowchart LR
  app[[Agent Studio]]
  jsonl[(Local JSONL trace)]
  logs[(Local log store)]
  metrics[(Local metric store)]
  verifiers([Verifier scripts and agents])
  app -- "every event, every field<br/>(unchanged)" --> jsonl
  app -- "loopback: every event,<br/>every field" --> logs
  app -- "loopback: listed measurements,<br/>queue stats once per process" --> metrics
  logs --> verifiers
  metrics --> verifiers
```

## Defined terms

| ID | Term | Identity rule | Relationships | Invariants | States |
| --- | --- | --- | --- | --- | --- |
| E1 | Recorded event | One call that records a trace event: an event name, attributes, resource, optional trace and span ids, and a time. Two calls are two events, even with identical content. | Produces one E2 when exported; may produce E3s. | Which events are recorded, and when, does not change. | recorded; dropped by the tag selection (unchanged) |
| E2 | Exported log record | The log record the local log store receives for one E1. | Exactly one per exported E1. | Carries every E1 attribute (E1 + E2 rule, R1). | exported; not exported because the endpoint is not loopback, or the tag is not selected |
| E3 | Metric sample | One value for one metric name and one label set, derived from a performance E1, or one queue-statistics value (E5). | Derived from an E1 attribute that is an E4, or from E5. | Exists only for an E4 or E5 (R4). | — |
| E4 | Measurement | A numeric attribute name the app records that is a real duration, count, size or occupancy. One name is one measurement, whatever event carries it. | Belongs to the explicit list. Becomes E3 samples. | Flags (0/1 state), sequence numbers and bookkeeping values are not measurements. | listed |
| E5 | Queue statistics | The trace export queue's dropped-record count, high-water mark and pending-request count. There is one set per app process. | Reported as process-level E3s. | Never copied as labels or samples onto other events' metric series. | — |
| E6 | Local observability stack | The log and metric stores at a loopback address that the app exports to. | Receives E2 and E3. | Export goes to loopback addresses only. | — |

## Requirements

| ID | Requirement | Over | From | Pass / fail |
| --- | --- | --- | --- | --- |
| R1 | When an E1 is exported, its E2 must carry every attribute of the E1: every string, number, boolean and string-array value, under the same name, with the same value. No allowlist of names or values may remove one. | E1, E2 | U1, U3 | Fail if any attribute present in the JSONL record is missing or changed in the exported log record. Examples: `sidebar.surface=panes`, `sidebar.sort_order`, `git.admission_to_status.elapsed_ms`. |
| R2 | Export must go only to loopback addresses. A non-loopback endpoint is refused and the app keeps writing JSONL, as today. | E6 | U3 | Fail if any record leaves for a non-loopback address. |
| R3 | Atoms-tagged events must stay excluded from the wildcard tag selection unless explicitly opted in, as today. | E1 | U3 | Fail if `*` alone exports atoms events. |
| R4 | E3 samples must come only from E4 names on one explicit measurement list, plus E5. Flags, sequence numbers and unlisted numeric attributes must produce no metric samples. They stay in logs (R1). | E3, E4, E5 | U2, U3 | Fail if a metric series exists for a flag, a sequence number, or a numeric name not on the list. |
| R5 | E3 labels must come only from the existing hand-picked label sets per event family. Sidebar `surface=panes` and grouping `activity` must be admitted as label values. | E3 | U2, U4 | Fail if a label outside the hand-picked sets appears, or if a Panes sidebar event produces no sidebar metrics. |
| R6 | E5 must be reported as process-level samples with no per-event label, and must not appear on any other event's metric series. Logs keep the copied queue fields on each event (R1). | E5, E3 | U3 | Fail if any non-queue event's metric series carries a queue statistic, or if queue statistics are missing at the process level. |
| R7 | After the change, the local metric store must hold no more series than before for the same workload, with the flag, sequence and per-event queue series gone. The before and after counts must be reported. | E3 | U2 | Fail if the series count grows, or if a removed category is still present. |
| R8 | The observability doc's OTLP projection section and the CLAUDE.md sentence that says OTLP output is source-scrubbed must describe the new behavior in the same change. The rewritten CLAUDE.md sentence must keep the R10 rule. | — | U3, U5 | Fail if either still describes the field filter, or if the CLAUDE.md sentence no longer says message text is never recorded in telemetry. |
| R9 | Verifier scripts that read the local stack must still pass. Their checks that IDs or paths are absent from exported logs are removed. Their checks that secret values are absent stay. | E2, E3 | U3 | Fail if a verifier fails because of this change, or if a secret-absence check was removed. |
| R10 | Agent message text must never be an E1 attribute value, so it reaches neither the JSONL trace nor any E2. Removing the field filter must not change this. | E1, E2 | U5 | Fail if the body of a pane message sent during a real debug launch appears in any JSONL record or in the local log store. |

If the local stack is unreachable, the app behaves as today: export failure is fail-open, and JSONL still writes. Which events are recorded, and when, does not change.

## Proof

| ID | Proves | Evidence |
| --- | --- | --- |
| V1 | R1 | Automated: for representative events from every family, including Panes sidebar, sort order, git timings and Bridge, the exported log record equals the recorded attributes, arrays included. |
| V2 | R2, R3 | The existing configuration tests (loopback accept and remote refuse; atoms opt-in) stay and pass unchanged. |
| V3 | R4, R5, R6 | Automated: metric samples appear only for listed measurements. Flags, sequences and unlisted numbers produce none. The Panes and activity labels are admitted. Queue statistics appear only as process-level series. |
| V4 | R1, R7 | A real debug launch exporting to the local stack, running the same workload before and after. Count series by category in the metric store, and query the log store for fields that used to be dropped. |
| V5 | R9 | Run the verifier scripts that read the local stack against the real debug launch, and check their secret-absence checks are still there. |
| V6 | R8 | Doc review of the two passages. |
| V7 | R10 | Marker-scoped real launch, before and after the change: send pane messages whose bodies carry a unique run id, then search every JSONL record and every exported log field for it. Expect zero hits, with a positive control that the same search finds a recorded pane id. Baseline: 0 hits on main b37828fba on 2026-10-12 (2,852 JSONL records, 3,177 log records). |
