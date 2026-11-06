#!/usr/bin/env bash
set -euo pipefail
# Keep the driver beside its mise task; an older source tree can be the declared target.
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec /usr/bin/python3 - "$PROJECT_ROOT" "$@" <<'PY'
import argparse
import datetime
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request

PREFIX = "agentstudio.performance.filesystem."
SCAN = PREFIX + "watched_scan."
CHANGE_REASONS = {"relevant_change", "native_coverage_loss", "intake_coverage_loss"}
EXPLICIT_REASONS = {"initial_add", "manual", "fallback", "retention"}
EVENTS = ("watched_scan_demand", "watched_scan_run", "watched_scan_obligation",
          "stage_outcome", "ingress_snapshot", "logical_debt")
RECORD_KEYS = {
    "watched_scan_demand": (SCAN + "reason",),
    "watched_scan_run": (SCAN + "service_duration_ms",),
    "watched_scan_obligation": (SCAN + "phase",),
    "stage_outcome": (PREFIX + "stage", PREFIX + "outcome"),
    "ingress_snapshot": (PREFIX + "ingress.local_raw_callback.event.count",),
    "logical_debt": (PREFIX + "logical_debt.count",),
}
UNAVAILABLE = "unavailable in v0.0.124 (no exported run/trigger identities)"


def require(condition, reason):
    if not condition:
        raise RuntimeError(reason)


def utc_now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z")


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def log_time(record):
    timestamp = record["_time"].replace("Z", "+00:00")
    # Victoria emits nanoseconds; Apple's Python 3.9 accepts microsecond precision.
    timestamp = re.sub(r"\.(\d+)(?=[+-])", lambda match: "." + match[1][:6].ljust(6, "0"), timestamp)
    return datetime.datetime.fromisoformat(timestamp).timestamp()


def number(record, name):
    value = record.get(PREFIX + name)
    require(value is not None, "telemetry_attribute_missing:" + name)
    result = float(value)
    require(math.isfinite(result) and result >= 0, "telemetry_attribute_invalid:" + name)
    return result


def scan_number(record, name):
    value = number(record, "watched_scan." + name)
    require(value.is_integer(), "telemetry_integer_required:" + name)
    return int(value)


def record_selector(event):
    # Victoria may retain OTLP attributes while omitting its log-body mapping.
    return " ".join(key + ":*" for key in RECORD_KEYS[event])


def record_matches(event, record):
    return all(key in record and record[key] != "" for key in RECORD_KEYS[event])


def canonical_membership_matches(paths, expected):
    canonical_paths = {str(Path(path).resolve()) for path in paths}
    return all((str(path.resolve()) in canonical_paths) == present for path, present in expected)


def validate_scan_record_shapes(demands, runs, closures):
    basic = {"folder_tag", "submission_sequence", "reason"}
    obligation_fields = {"obligation_ordinal", "interval_ordinal", "first_trigger_offset_ms", "last_trigger_offset_ms",
                         "quiet_gap_count", "folded_trigger_count", "obligation_wait_ms"}
    fixture_names = ("asw.v9.", "repository", "control", "removed", "created", "files-", "item-")
    for row in demands + runs + closures:
        for key, value in row.items():
            if key.startswith(SCAN) and isinstance(value, str):
                require("/" not in value and "\\" not in value and not any(name in value for name in fixture_names),
                        "telemetry_contains_path_or_fixture_name")
    for demand in demands:
        fields = {key[len(SCAN):] for key in demand if key.startswith(SCAN)}
        require(basic <= fields, "demand_identity_fields_missing")
        reason = demand[SCAN + "reason"]
        require(reason in CHANGE_REASONS | EXPLICIT_REASONS, "demand_reason_invalid")
        if "obligation_ordinal" in fields:
            require(obligation_fields <= fields, "obligation_demand_fields_incomplete")
        else:
            require(fields == basic and reason in EXPLICIT_REASONS, "explicit_only_demand_shape_invalid")
        for field in fields - {"folder_tag", "reason"}:
            scan_number(demand, field)
    for run in runs:
        require(SCAN + "folder_tag" in run, "run_folder_tag_missing")
        for field in ("submission_sequence", "demand_generation", "scan_run_generation", "service_duration_ms"):
            scan_number(run, field)
    for closure in closures:
        require(closure.get(SCAN + "phase") == "closed", "obligation_not_closed")
        for field in ("obligation_ordinal", "span_ms", "quiet_gap_count", "scan_run_generation", "attributed_run_count"):
            scan_number(closure, field)


def split_coarse_recoveries(records):
    counts = {"watched_folder": 0, "worktree": 0}
    for row in records:
        if row.get(PREFIX + "stage") != "overflow_recovery":
            continue
        kind = row.get(PREFIX + "registration_kind")
        require(kind in counts, "overflow_registration_kind_missing_or_invalid")
        if row.get(PREFIX + "outcome") == "overflow_coarse":
            counts[kind] += 1
    return counts


def validate_baseline(baseline, fingerprint, adopted_marker):
    if baseline.get("status") == "bounded_baseline_observation":
        require(adopted_marker is not None and adopted_marker == baseline.get("traceName"), "bounded_baseline_not_adopted")
    else:
        require(baseline.get("status") == "valid_baseline", "baseline_invalid")
    require(baseline["fixtureFingerprint"] == fingerprint, "baseline_fixture_mismatch")
    require(baseline["watchedFolderCoarseRecoveries"] > 0, "baseline_no_watched_folder_coarse_recoveries")


def analyze_obligations(demands, runs, closures):
    require(closures, "obligation_closure_missing")
    validate_scan_record_shapes(demands, runs, closures)
    tags = {row.get(SCAN + "folder_tag") for row in demands + runs + closures}
    require(len(tags) == 1 and None not in tags, "watched_folder_tag_not_unique")
    for row in demands + runs + closures:
        for key_name, value in row.items():
            if key_name.startswith(SCAN) and isinstance(value, str):
                require("/" not in value and "\\" not in value, "telemetry_contains_path")
    demand_keys = {}
    for demand in demands:
        key = (demand[SCAN + "folder_tag"], int(scan_number(demand, "submission_sequence")))
        require(key not in demand_keys, "duplicate_demand_sequence")
        demand_keys[key] = demand
        reason = demand.get(SCAN + "reason")
        require(reason in CHANGE_REASONS | EXPLICIT_REASONS, "demand_reason_invalid")
        if reason in EXPLICIT_REASONS and SCAN + "obligation_ordinal" not in demand:
            continue
        for field in ("obligation_ordinal", "interval_ordinal", "first_trigger_offset_ms",
                      "last_trigger_offset_ms", "quiet_gap_count", "folded_trigger_count", "obligation_wait_ms"):
            scan_number(demand, field)
        require(demand.get(SCAN + "reason"), "demand_reason_missing")
    completed = {}
    joined = []
    for run in runs:
        tag = run[SCAN + "folder_tag"]
        generation = int(scan_number(run, "scan_run_generation"))
        key = (tag, generation)
        require(key not in completed, "duplicate_completed_run")
        sequence = int(scan_number(run, "submission_sequence"))
        demand = demand_keys.get((tag, sequence))
        require(demand is not None, "run_without_demand")
        scan_number(run, "service_duration_ms")
        scan_number(run, "demand_generation")
        completed[key] = run
        joined.append({"folder_tag": tag, "scan_run_generation": generation,
                       "submission_sequence": sequence,
                       "obligation_ordinal": int(demand.get(SCAN + "obligation_ordinal", 0)),
                       "demand": demand, "run": run})
    results = []
    seen = set()
    for closure in closures:
        require(closure.get(SCAN + "phase") == "closed", "obligation_not_closed")
        tag = closure[SCAN + "folder_tag"]
        ordinal = int(scan_number(closure, "obligation_ordinal"))
        require((tag, ordinal) not in seen, "duplicate_obligation_closure")
        seen.add((tag, ordinal))
        span = scan_number(closure, "span_ms")
        quiet = int(scan_number(closure, "quiet_gap_count"))
        attributed = int(scan_number(closure, "attributed_run_count"))
        closing = int(scan_number(closure, "scan_run_generation"))
        require((tag, closing) in completed, "closing_run_missing")
        require(completed[(tag, closing)].get(SCAN + "obligation_ordinal") is not None,
                "closing_run_obligation_missing")
        require(scan_number(completed[(tag, closing)], "obligation_ordinal") == ordinal,
                "closing_run_obligation_mismatch")
        actual = [row for row in joined if row["folder_tag"] == tag
                  and row["obligation_ordinal"] == ordinal
                  and row["demand"].get(SCAN + "reason") in CHANGE_REASONS]
        require(len(actual) == attributed, "attributed_run_count_mismatch")
        bound = 1 + quiet + math.ceil(span / 10000)
        require(attributed <= bound, "completed_run_bound_exceeded")
        results.append({"folder_tag": tag, "obligation_ordinal": ordinal, "span_ms": span,
                        "quiet_gap_count": quiet, "completedRuns": attributed, "bound": bound,
                        "closing_run_generation": closing})
    for row in joined:
        if row["obligation_ordinal"] > 0:
            require((row["folder_tag"], row["obligation_ordinal"]) in seen, "obligation_still_open")
    for (tag, sequence), demand in demand_keys.items():
        ordinal = int(demand.get(SCAN + "obligation_ordinal", 0))
        if ordinal > 0:
            require((tag, ordinal) in seen, "obligation_still_open")
            require(any(row["folder_tag"] == tag and row["submission_sequence"] >= sequence
                        for row in joined), "demand_without_covering_run")
    return {"obligations": results, "joined": joined}


def settled_debt_evidence(logs, exports, after, creation_published=True):
    require(creation_published, "creation_publication_fence_missing")
    fresh = [row for row in logs if log_time(row) >= after]
    require(fresh and number(fresh[-1], "logical_debt.count") == 0, "fresh_debt_log_not_zero")
    zero_log_time = log_time(fresh[-1])
    samples = {}
    for row in exports:
        require(len(row["timestamps"]) == len(row["values"]), "raw_gauge_lengths_differ")
        for timestamp, value in zip(row["timestamps"], row["values"]):
            if timestamp / 1000 <= zero_log_time:
                continue
            require(math.isfinite(value) and value >= 0, "raw_gauge_invalid")
            require(timestamp not in samples or samples[timestamp] == value, "raw_gauge_conflicting_timestamp")
            samples[timestamp] = value
    require(len(samples) >= 2, "two_distinct_gauge_exports_missing")
    require(all(value == 0 for value in samples.values()), "nonzero_gauge_after_zero_log")
    return {"latestZeroDebtLog": fresh[-1], "rawZeroGaugeSamples": sorted(samples.items())}


def quiet_tail_evidence(ingress, after):
    rows = [row for row in ingress if log_time(row) >= after]
    require(len(rows) >= 3, "quiet_tail_exports_missing")
    require(len({log_time(row) for row in rows}) == len(rows), "duplicate_ingress_export_timestamp")
    last_increase = after
    total = 0
    quiet_exports = 0
    for row in rows:
        count = number(row, "ingress.local_raw_callback.event.count")
        total += count
        if count > 0:
            last_increase = log_time(row)
            quiet_exports = 0
        else:
            quiet_exports += 1
    require(quiet_exports >= 3, "quiet_tail_counter_still_growing")
    require(log_time(rows[-1]) - last_increase >= 60, "quiet_tail_shorter_than_60_seconds")
    return {"rawEvents": total, "consecutiveUnchangedExports": quiet_exports,
            "lastIncreaseUnixSeconds": last_increase, "lastExportUnixSeconds": log_time(rows[-1])}


def require_metrics_latency_offset(value):
    require(value == "1ms", "metrics_latency_offset_must_be_one_millisecond")


def candidate_cli_environment(ambient, candidate, escrow_path, escrow, metadata):
    require(candidate.get("AGENTSTUDIO_OBSERVABILITY_STATUS") == "running"
            and candidate.get("AGENTSTUDIO_OBSERVABILITY_RUNTIME_FLAVOR") == "debug"
            and candidate.get("AGENTSTUDIO_OBSERVABILITY_IPC_AUTH_MODE") == "authenticated",
            "candidate_ipc_identity_invalid")
    expected_socket = Path(candidate["AGENTSTUDIO_OBSERVABILITY_DATA_DIR"]) / "ipc-socket/agentstudio.sock"
    require(isinstance(metadata.get("socketPath"), str) and isinstance(escrow.get("socketPath"), str)
            and Path(metadata["socketPath"]).resolve() == expected_socket.resolve()
            and Path(escrow["socketPath"]).resolve() == expected_socket.resolve(), "candidate_ipc_socket_mismatch")
    require(metadata.get("channel") == "debug" and metadata.get("protocol") == "agentstudio-ipc-jsonrpc-2"
            and metadata.get("processIdentifier") == int(candidate["AGENTSTUDIO_OBSERVABILITY_PID"]),
            "candidate_ipc_runtime_metadata_mismatch")
    require(isinstance(escrow.get("runtimeId"), str) and escrow["runtimeId"]
            and escrow["runtimeId"] == metadata.get("runtimeId"), "candidate_ipc_runtime_id_mismatch")
    require(isinstance(escrow.get("token"), str) and escrow["token"], "candidate_ipc_credential_missing")
    # CLI parseGlobal/discovery read IPC_SOCKET, PANE_TOKEN and IPC_DEBUG_TOKEN_ESCROW;
    # pane/outbox support also reads PANE_ID, WORKSPACE_ID, CLI_STORE and CLI_STORE_CHANNEL.
    # Start fresh so none of those ambient AGENTSTUDIO_* bindings (or future ones) survive.
    # --socket must stay absent: it deliberately disables the CLI's escrow credential path.
    return {"HOME": ambient["HOME"], "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "AGENTSTUDIO_IPC_DEBUG_TOKEN_ESCROW": str(escrow_path)}


WORKLOAD_HARD_CAP_SECONDS = 45 * 60


def enforce_workload_hard_cap(now, action_started):
    require(action_started is None or now < action_started + WORKLOAD_HARD_CAP_SECONDS,
            "workload_hard_cap_exceeded")


def observe_until_ready(observe, check_exit, pause):
    last_error = "no matching observation"
    while True:
        check_exit(last_error)
        try:
            result = observe()
        except (RuntimeError, OSError, ValueError, KeyError) as error:
            last_error = str(error)
            result = None
        check_exit(last_error)
        if result:
            return result
        pause()


def self_test():
    def record(**fields):
        return {SCAN + key: value for key, value in fields.items()}
    demand = record(folder_tag="tag", submission_sequence=1, obligation_ordinal=1,
                    interval_ordinal=1, reason="relevant_change", first_trigger_offset_ms=0,
                    last_trigger_offset_ms=0, quiet_gap_count=0, folded_trigger_count=1, obligation_wait_ms=2000)
    run = record(folder_tag="tag", submission_sequence=1, scan_run_generation=1, service_duration_ms=10, demand_generation=1, obligation_ordinal=1)
    closure = record(folder_tag="tag", obligation_ordinal=1, phase="closed", span_ms=0,
                     quiet_gap_count=0, attributed_run_count=1, scan_run_generation=1)
    require(analyze_obligations([demand], [run], [closure])["obligations"][0]["bound"] == 1,
            "self_test_valid_case")
    cases = [( [], [run], [closure], "run_without_demand"),
             ([demand], [run], [], "obligation_closure_missing"),
             ([demand], [], [closure], "closing_run_missing"),
             ([demand], [run], [dict(closure, **{SCAN + "attributed_run_count": 2})],
              "attributed_run_count_mismatch")]
    for demands, runs, closures, expected in cases:
        try:
            analyze_obligations(demands, runs, closures)
        except RuntimeError as error:
            require(str(error) == expected, "self_test_wrong_rejection:" + str(error))
        else:
            raise RuntimeError("self_test_missed_rejection:" + expected)
    second_demand = dict(demand, **{SCAN + "submission_sequence": 2})
    second_run = dict(run, **{SCAN + "submission_sequence": 2, SCAN + "scan_run_generation": 2})
    two_runs = dict(closure, **{SCAN + "attributed_run_count": 2, SCAN + "scan_run_generation": 2})
    try:
        analyze_obligations([demand, second_demand], [run, second_run], [two_runs])
    except RuntimeError as error:
        require(str(error) == "completed_run_bound_exceeded", "self_test_bound_reason")
    else:
        raise RuntimeError("self_test_missed_bound_violation")
    allowed_gap = dict(two_runs, **{SCAN + "quiet_gap_count": 1})
    require(analyze_obligations([demand, second_demand], [run, second_run], [allowed_gap])
            ["obligations"][0]["bound"] == 2, "self_test_rejected_allowed_gap")
    allowed_span = dict(two_runs, **{SCAN + "span_ms": 10001})
    require(analyze_obligations([demand, second_demand], [run, second_run], [allowed_span])
            ["obligations"][0]["bound"] == 3, "self_test_span_units")
    require(canonical_membership_matches(["/tmp"], [(Path("/private/tmp"), True)]),
            "self_test_tmp_realpath_alias")
    require(not canonical_membership_matches(["/tmp"], [(Path("/private/tmp"), False)]),
            "self_test_tmp_realpath_wrong_membership")
    require(log_time({"_time": "2026-11-05T11:55:13.123456789Z"}) ==
            log_time({"_time": "2026-11-05T11:55:13.123456Z"}), "self_test_victoria_nanoseconds")
    require(log_time({"_time": "2026-11-05T11:55:13.1Z"}) ==
            log_time({"_time": "2026-11-05T11:55:13.100000Z"}), "self_test_victoria_short_fraction")
    legacy_run = dict(run)
    del legacy_run[SCAN + "service_duration_ms"]
    legacy_run[SCAN + "duration_ms"] = 10
    try:
        analyze_obligations([demand], [legacy_run], [closure])
    except RuntimeError as error:
        require(str(error) == "telemetry_attribute_missing:watched_scan.service_duration_ms",
                "self_test_service_duration_reason")
    else:
        raise RuntimeError("self_test_accepted_retired_duration_key")
    raw_ingress = {"_time": "2026-11-05T14:00:33.682768Z",
                   "service.name": "AgentStudio", "agent.proof.marker": "fixture-marker",
                   PREFIX + "ingress.local_raw_callback.event.count": "0"}
    raw_debt = {PREFIX + "logical_debt.count": "0"}
    raw_stage = {PREFIX + "stage": "overflow_recovery", PREFIX + "outcome": "overflow_coarse"}
    for event, raw in (("ingress_snapshot", raw_ingress), ("logical_debt", raw_debt),
                       ("stage_outcome", raw_stage), ("watched_scan_demand", demand),
                       ("watched_scan_run", run), ("watched_scan_obligation", closure)):
        require("_msg" not in raw and record_matches(event, raw), "self_test_attribute_identity:" + event)
        require(record_selector(event) and "_msg" not in record_selector(event), "self_test_selector:" + event)
    require(not record_matches("logical_debt", raw_ingress), "self_test_ingress_misidentified_as_debt")
    require(not record_matches("watched_scan_demand", run), "self_test_run_misidentified_as_demand")
    debt_log = {"_time": "2026-11-05T14:00:00Z", PREFIX + "logical_debt.count": "0"}
    zero_time = log_time(debt_log)
    exports = [{"timestamps": [int((zero_time + 60) * 1000), int((zero_time + 120) * 1000)], "values": [0, 0]}]
    require(len(settled_debt_evidence([debt_log], exports, zero_time)["rawZeroGaugeSamples"]) == 2,
            "self_test_two_zero_settle")
    bad_exports = [exports[0], {"timestamps": [int((zero_time + 90) * 1000)], "values": [1]}]
    for raw, reason in ((bad_exports, "nonzero_gauge_after_zero_log"),
                        ([{"timestamps": [int((zero_time + 60) * 1000)] * 2, "values": [0, 0]}],
                         "two_distinct_gauge_exports_missing")):
        try:
            settled_debt_evidence([debt_log], raw, zero_time)
        except RuntimeError as error:
            require(str(error) == reason, "self_test_debt_settle_reason")
        else:
            raise RuntimeError("self_test_missed_debt_settle_rejection")
    try:
        settled_debt_evidence([debt_log], exports, zero_time, creation_published=False)
    except RuntimeError as error:
        require(str(error) == "creation_publication_fence_missing", "self_test_publication_fence_reason")
    else:
        raise RuntimeError("self_test_settled_before_creation_publication")
    def ingress(second, count):
        return {"_time": "2026-11-05T14:%02d:%02dZ" % divmod(second, 60),
                PREFIX + "ingress.local_raw_callback.event.count": count}
    require(quiet_tail_evidence([ingress(0, 5), ingress(20, 0), ingress(40, 0), ingress(60, 0)],
                               zero_time)["rawEvents"] == 5, "self_test_quiet_tail")
    try:
        quiet_tail_evidence([ingress(0, 5), ingress(20, 0), ingress(40, 1), ingress(60, 0)], zero_time)
    except RuntimeError as error:
        require(str(error) == "quiet_tail_counter_still_growing", "self_test_growing_counter_reason")
    else:
        raise RuntimeError("self_test_closed_with_growing_counter")
    require_metrics_latency_offset("1ms")
    try:
        require_metrics_latency_offset("0")
    except RuntimeError as error:
        require(str(error) == "metrics_latency_offset_must_be_one_millisecond", "self_test_latency_offset_reason")
    else:
        raise RuntimeError("self_test_accepted_zero_latency_offset")
    explicit = record(folder_tag="tag", submission_sequence=3, reason="fallback")
    validate_scan_record_shapes([explicit], [], [])
    shape_cases = [([dict(explicit, **{SCAN + "interval_ordinal": 1})], [], [], "explicit_only_demand_shape_invalid"),
                   ([{key: value for key, value in demand.items() if key != SCAN + "quiet_gap_count"}], [], [], "obligation_demand_fields_incomplete"),
                   ([dict(demand, **{SCAN + "folder_tag": "control"})], [], [], "telemetry_contains_path_or_fixture_name")]
    for demand_rows, run_rows, closure_rows, expected in shape_cases:
        try:
            validate_scan_record_shapes(demand_rows, run_rows, closure_rows)
        except RuntimeError as error:
            require(str(error) == expected, "self_test_shape_reason")
        else:
            raise RuntimeError("self_test_shape_accepted_invalid_record")
    bounded = {"status": "bounded_baseline_observation", "traceName": "marker1423", "fixtureFingerprint": "fixture", "coarseRecoveries": 453, "watchedFolderCoarseRecoveries": 200}
    validate_baseline(bounded, "fixture", "marker1423")
    for adoption in (None, "different-marker"):
        try:
            validate_baseline(bounded, "fixture", adoption)
        except RuntimeError as error:
            require(str(error) == "bounded_baseline_not_adopted", "self_test_baseline_adoption_reason")
        else:
            raise RuntimeError("self_test_baseline_adoption_missing")
    rows = [{PREFIX + "stage": "overflow_recovery", PREFIX + "outcome": "overflow_coarse",
             PREFIX + "registration_kind": kind} for kind in ("watched_folder", "worktree", "worktree")]
    require(split_coarse_recoveries(rows) == {"watched_folder": 1, "worktree": 2}, "self_test_coarse_kind_split")
    require(split_coarse_recoveries([{PREFIX + "stage": "affected_key_apply", PREFIX + "outcome": "applied"}]) ==
            {"watched_folder": 0, "worktree": 0}, "self_test_nonoverflow_not_classified")
    for kind in (None, "unknown"):
        invalid = dict(rows[0]); invalid[PREFIX + "registration_kind"] = kind
        try:
            split_coarse_recoveries([invalid])
        except RuntimeError as error:
            require(str(error) == "overflow_registration_kind_missing_or_invalid", "self_test_kind_reason")
        else:
            raise RuntimeError("self_test_unattributed_overflow_accepted")
    require(split_coarse_recoveries(rows)["watched_folder"] * 10 <= 10,
            "self_test_watched_folder_threshold")
    candidate = {"AGENTSTUDIO_OBSERVABILITY_STATUS": "running", "AGENTSTUDIO_OBSERVABILITY_RUNTIME_FLAVOR": "debug",
                 "AGENTSTUDIO_OBSERVABILITY_IPC_AUTH_MODE": "authenticated", "AGENTSTUDIO_OBSERVABILITY_PID": "123",
                 "AGENTSTUDIO_OBSERVABILITY_DATA_DIR": "/private/tmp/asw.v9.fixture/data"}
    socket_path = "/private/tmp/asw.v9.fixture/data/ipc-socket/agentstudio.sock"
    escrow = {"socketPath": socket_path, "runtimeId": "candidate-runtime", "token": "fixture-token"}
    metadata = {"socketPath": socket_path, "runtimeId": "candidate-runtime", "processIdentifier": 123,
                "channel": "debug", "protocol": "agentstudio-ipc-jsonrpc-2"}
    ambient = {"HOME": "/fixture-home", "PATH": "/usr/bin:/bin", "AGENTSTUDIO_IPC_SOCKET": "/ambient/socket",
               "AGENTSTUDIO_PANE_TOKEN": "ambient-fixture-token", "AGENTSTUDIO_PANE_ID": "ambient-pane",
               "AGENTSTUDIO_WORKSPACE_ID": "ambient-workspace", "AGENTSTUDIO_CLI_STORE": "/ambient/store",
               "AGENTSTUDIO_CLI_STORE_CHANNEL": "stable", "AGENTSTUDIO_IPC_DEBUG_TOKEN_ESCROW": "/ambient/escrow"}
    cli_environment = candidate_cli_environment(ambient, candidate, "/candidate/escrow.json", escrow, metadata)
    child = subprocess.check_output([sys.executable, "-c",
        "import os,json; print(json.dumps({key:value for key,value in os.environ.items() if key.startswith('AGENTSTUDIO_')}))"],
        env=cli_environment, text=True, timeout=15)
    require(json.loads(child) == {"AGENTSTUDIO_IPC_DEBUG_TOKEN_ESCROW": "/candidate/escrow.json"},
            "self_test_ambient_ipc_binding_leaked_to_subprocess")
    binding_cases = [
        (dict(candidate, AGENTSTUDIO_OBSERVABILITY_RUNTIME_FLAVOR="stable"), escrow, metadata, "candidate_ipc_identity_invalid"),
        (candidate, dict(escrow, socketPath="/ambient/socket"), metadata, "candidate_ipc_socket_mismatch"),
        (candidate, escrow, dict(metadata, processIdentifier=999), "candidate_ipc_runtime_metadata_mismatch"),
        (candidate, escrow, dict(metadata, channel="stable"), "candidate_ipc_runtime_metadata_mismatch"),
        (candidate, dict(escrow, runtimeId="foreign-runtime"), metadata, "candidate_ipc_runtime_id_mismatch"),
        (candidate, dict(escrow, token=""), metadata, "candidate_ipc_credential_missing"),
    ]
    for state_value, escrow_value, metadata_value, expected in binding_cases:
        try:
            candidate_cli_environment(ambient, state_value, "/candidate/escrow.json", escrow_value, metadata_value)
        except RuntimeError as error:
            require(str(error) == expected, "self_test_candidate_binding_reason")
        else:
            raise RuntimeError("self_test_accepted_foreign_candidate_binding")
    controlled = {"now": 0, "last_raw": 0, "cleaned": False}
    clock_trace = iter((900, 1800, 2700, 3600, 4500))
    def advancing_raw_counter():
        controlled["last_raw"] = controlled["now"]
        raise RuntimeError("quiet_tail_counter_still_growing")
    def check_controlled_exit(_):
        enforce_workload_hard_cap(controlled["now"], 0)
        require(controlled["now"] < controlled["last_raw"] + 1200, "self_test_unexpected_quiet_cutoff")
    def advance_controlled_clock():
        try:
            controlled["now"] = next(clock_trace)
        except StopIteration:
            raise AssertionError("self_test_advancing_raw_counter_escaped_hard_cap")
    try:
        observe_until_ready(advancing_raw_counter, check_controlled_exit, advance_controlled_clock)
    except RuntimeError as error:
        require(str(error) == "workload_hard_cap_exceeded", "self_test_hard_cap_exit_reason")
    finally:
        controlled["cleaned"] = True
    require(controlled["cleaned"] and controlled["now"] == WORKLOAD_HARD_CAP_SECONDS,
            "self_test_hard_cap_did_not_reach_cleanup")
    result = observe_until_ready(lambda: "closed", lambda _: enforce_workload_hard_cap(WORKLOAD_HARD_CAP_SECONDS - 1, 0),
                                 lambda: (_ for _ in ()).throw(AssertionError("self_test_success_waited")))
    require(result == "closed", "self_test_hard_cap_rejected_timely_closure")
    enforce_workload_hard_cap(WORKLOAD_HARD_CAP_SECONDS * 2, None)
    print("driver self-test: 50 passed, 0 failed; no app, fixture or network")


def main():
    parser = argparse.ArgumentParser(description="V9 watched-folder burst journey; Victoria evidence only.")
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--target-root", type=Path, default=Path(sys.argv[1]))
    parser.add_argument("--expected-head", help="Required exact source commit for the launched debug build")
    parser.add_argument("--mode", choices=("baseline", "head"), default="head")
    parser.add_argument("--baseline", type=Path, help="Baseline summary.json; required for head mode")
    parser.add_argument("--adopt-bounded-baseline-marker", help="Explicitly adopted bounded comparator marker; default rejects bounded baselines")
    parser.add_argument("--proof-root", type=Path, default=Path(tempfile.gettempdir()) / "watched-folder-v9")
    parser.add_argument("--files", type=int, default=150000)
    parser.add_argument("--timeout", type=int, default=600, help="Per-readiness wait hang bound; measured work also has a fixed 45-minute cap from action start")
    parser.add_argument("--instrumentation-patch", type=Path, help="Approved telemetry-only patch on peeled v0.0.124")
    parser.add_argument("--expected-instrumentation-sha256", help="Independent digest from the baseline commission")
    parser.add_argument("--skip-build", action="store_true", help="Use only the declared target's prepared build")
    args = parser.parse_args(sys.argv[2:])
    if args.self_test:
        self_test()
        return
    require(args.expected_head, "declared_head_required")
    require(args.files > 256 and args.timeout > 0, "invalid_fixture_parameters")
    require(args.mode == "baseline" or args.baseline, "baseline_summary_required")
    target = args.target_root.resolve()
    trace = os.environ.get("AGENTSTUDIO_TRACE_NAME", "watched-v9-" + datetime.datetime.now().strftime("%Y%m%d%H%M%S") + "-" + str(os.getpid()))
    require(re.fullmatch(r"[A-Za-z0-9_-][A-Za-z0-9_.-]*", trace), "invalid_trace_name")
    artifact = args.proof_root.resolve() / trace
    artifact.mkdir(parents=True, exist_ok=False)
    os.chmod(artifact, 0o700)
    print("artifact=" + str(artifact), flush=True)
    summary = {"status": "invalid", "mode": args.mode, "traceName": trace, "targetRoot": str(target),
               "validity": {}, "files": args.files,
               "fixtureFingerprint": "v1:one-root:two-repos:remove-then-create:files=" + str(args.files)}
    runtime = None
    launch_attempted = False
    sample_process = None
    action_monotonic = None
    environment = os.environ.copy()
    launcher = target / "scripts/run-debug-observability.sh"
    state_file = artifact / "debug-observability.env"
    command_log = artifact / "commands.log"

    def command(arguments, *, capture=False, cwd=target, timeout=120, subprocess_environment=None):
        with command_log.open("a") as output:
            output.write(shlex.join(str(value) for value in arguments) + "\n")
        result = subprocess.run([str(value) for value in arguments], cwd=cwd, env=environment if subprocess_environment is None else subprocess_environment,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=timeout)
        if not capture:
            with (artifact / "commands-output.log").open("a") as output:
                output.write(result.stdout + result.stderr)
        require(result.returncode == 0, "command_failed:" + str(arguments[0]) + ":" + str(result.returncode))
        return result.stdout

    def verify_checkout():
        status = command(["git", "status", "--porcelain"], capture=True)
        summary["sourceStatus"] = status
        allowed = {"docs/images/agent-studio-file-diff-review.png",
                   "docs/images/agent-studio-pane-drawers.png",
                   "docs/images/agent-studio-parallel-agent-terminals.png",
                   "docs/images/agent-studio-repository-command-bar.png"}
        verified = []
        for line in status.splitlines():
            path = line[3:]
            require(args.mode == "baseline" and line[:3] == " M " and path in allowed,
                    "declared_target_dirty:" + path)
            pointer = command(["git", "show", "HEAD:" + path], capture=True)
            match = re.fullmatch(r"version https://git-lfs.github.com/spec/v1\noid sha256:([0-9a-f]{64})\nsize ([0-9]+)\n", pointer)
            require(match, "baseline_docs_lfs_pointer_invalid:" + path)
            payload = (target / path).read_bytes()
            digest = hashlib.sha256(payload).hexdigest()
            require(digest == match[1] and len(payload) == int(match[2]), "baseline_docs_lfs_object_mismatch:" + path)
            verified.append({"path": path, "sha256": digest, "size": len(payload)})
        summary["baselineDocsLFSExceptions"] = verified
        summary["validity"]["buildInputsMatchDeclaredHead"] = True

    def state():
        result = {}
        for line in state_file.read_text().splitlines():
            key, separator, value = line.partition("=")
            if separator:
                parsed = shlex.split(value)
                result[key] = parsed[0] if parsed else ""
        return result

    urls = {"logs": os.environ.get("AI_TOOLS_OBSERVABILITY_LOGS_QUERY_URL", "http://127.0.0.1:9428/select/logsql/query"),
            "metrics": os.environ.get("AI_TOOLS_OBSERVABILITY_METRICS_QUERY_URL", "http://127.0.0.1:8428/api/v1/query")}
    for url in urls.values():
        parsed = urllib.parse.urlparse(url)
        require(parsed.scheme == "http" and parsed.hostname in ("127.0.0.1", "localhost", "::1"), "non_loopback_query_url")

    def query(kind, expression, **parameters):
        if kind == "metrics":
            require_metrics_latency_offset(parameters.get("latency_offset"))
        with (artifact / "queries.log").open("a") as output:
            output.write(kind + " " + expression + " " + json.dumps(parameters) + "\n")
        parameters["query"] = expression
        with urllib.request.urlopen(urls[kind] + "?" + urllib.parse.urlencode(parameters), timeout=15) as response:
            return response.read().decode()

    marker = '{service.name="AgentStudio",dev.runtime.flavor="debug"} agent.proof.marker:=' + json.dumps(trace)

    def records(event, end=None):
        expression = marker + " " + record_selector(event)
        parameters = {"end": end} if end is not None else {}
        response = query("logs", expression + " | sort by (_time) | limit 200000", limit=200000, **parameters)
        rows = [json.loads(line) for line in response.splitlines() if line.strip()]
        require(all(record_matches(event, row) for row in rows), "telemetry_record_kind_mismatch:" + event)
        count_response = query("logs", expression + " | stats count() as records", **parameters)
        counts = [json.loads(line) for line in count_response.splitlines() if line.strip()]
        require(len(counts) == 1 and int(counts[0]["records"]) == len(rows), "telemetry_query_truncated:" + event)
        (artifact / (event + ".ndjson")).write_text(response)
        return rows

    def metric(name):
        expression = 'max(' + name + '{service.name="AgentStudio",dev.runtime.flavor="debug",agent.proof.marker=' + json.dumps(trace) + '})'
        response = json.loads(query("metrics", expression, latency_offset="1ms"))
        write_json(artifact / (name + ".json"), response)
        require(response.get("status") == "success", "metrics_query_failed:" + name)
        rows = response["data"]["result"]
        require(len(rows) == 1, "telemetry_metric_missing:" + name)
        value = float(rows[0]["value"][1])
        require(math.isfinite(value), "telemetry_metric_invalid:" + name)
        return value

    def event_count(event):
        expression = ('sum(agentstudio_performance_events_total{service.name="AgentStudio",'
                      'dev.runtime.flavor="debug",agent.proof.marker=' + json.dumps(trace) +
                      ',event=' + json.dumps("performance.filesystem." + event) + '})')
        response = json.loads(query("metrics", expression, latency_offset="1ms"))
        write_json(artifact / (event + "-counter.json"), response)
        require(response.get("status") == "success", "metrics_event_count_failed:" + event)
        rows = response["data"]["result"]
        return float(rows[0]["value"][1]) if len(rows) == 1 else 0

    def registration_kind_metric_count(kind):
        expression = ('sum(agentstudio_performance_events_total{service.name="AgentStudio",'
                      'dev.runtime.flavor="debug",agent.proof.marker=' + json.dumps(trace) +
                      ',event="performance.filesystem.stage_outcome",stage="overflow_recovery",'
                      'outcome="overflow_coarse",registration_kind=' + json.dumps(kind) + '})')
        response = json.loads(query("metrics", expression, latency_offset="1ms"))
        write_json(artifact / (kind + "-coarse-counter.json"), response)
        require(response.get("status") == "success", "kind_metric_query_failed")
        rows = response["data"]["result"]
        return float(rows[0]["value"][1]) if len(rows) == 1 else 0

    def debt_settle(after, name):
        selector = ('agentstudio_performance_filesystem_logical_debt_count{service.name="AgentStudio",'
                    'dev.runtime.flavor="debug",agent.proof.marker=' + json.dumps(trace) + '}')
        parameters = {"match[]": selector, "start": after, "end": time.time(), "reduce_mem_usage": "1"}
        with (artifact / "queries.log").open("a") as output:
            output.write("metrics-raw /api/v1/export " + json.dumps(parameters) + "\n")
        export_url = urls["metrics"].rsplit("/", 1)[0] + "/export?" + urllib.parse.urlencode(parameters)
        with urllib.request.urlopen(export_url, timeout=15) as response:
            raw = response.read().decode()
        (artifact / (name + "-debt-raw.ndjson")).write_text(raw)
        exports = [json.loads(line) for line in raw.splitlines() if line.strip()]
        require(all(row["metric"].get("agent.proof.marker") == trace for row in exports), "raw_gauge_marker_mismatch")
        result = settled_debt_evidence(records("logical_debt"), exports, after,
                                       summary["validity"].get("creationMembershipPublished", False))
        write_json(artifact / (name + "-debt-settle.json"), result)
        return result

    def ipc(method):
        latest_state = state()
        for key in ("AGENTSTUDIO_OBSERVABILITY_PID", "AGENTSTUDIO_OBSERVABILITY_PROCESS_START_IDENTITY",
                    "AGENTSTUDIO_OBSERVABILITY_DEBUG_CODE", "AGENTSTUDIO_OBSERVABILITY_DATA_DIR",
                    "AGENTSTUDIO_OBSERVABILITY_EXECUTABLE"):
            require(latest_state.get(key) == current.get(key), "candidate_ipc_launch_state_changed")
        escrow = json.loads((artifact / "ipc-escrow.json").read_text())
        metadata = json.loads((Path(current["AGENTSTUDIO_OBSERVABILITY_DATA_DIR"]) / "ipc/runtime.json").read_text())
        cli_environment = candidate_cli_environment(environment, latest_state, artifact / "ipc-escrow.json", escrow, metadata)
        if candidate_runtime_id is not None:
            require(metadata["runtimeId"] == candidate_runtime_id, "candidate_ipc_runtime_changed")
        result = json.loads(command([cli, method], capture=True, timeout=15, subprocess_environment=cli_environment))
        require("error" not in result, "ipc_error:" + method)
        return result.get("result", result)

    def wait_for(description, observe, raw_quiet_cutoff=False):
        deadline = time.monotonic() + args.timeout

        def check_exit(last_error):
            enforce_workload_hard_cap(time.monotonic(), action_monotonic)
            if launch_attempted and state_file.exists():
                current = state()
                if current.get("AGENTSTUDIO_OBSERVABILITY_STATUS") == "running":
                    try:
                        os.kill(int(current["AGENTSTUDIO_OBSERVABILITY_PID"]), 0)
                    except ProcessLookupError:
                        raise RuntimeError("debug_app_retired_while_waiting:" + description)
            if raw_quiet_cutoff:
                cutoff = summary.get("lastRawEventUnixSeconds", action_start) + 1200
                if time.time() >= cutoff:
                    summary["boundedCutoffUTC"] = datetime.datetime.fromtimestamp(cutoff, datetime.timezone.utc).isoformat()
                    summary["observationStatus"] = "NOT PASSED (bounded cutoff)"
                    raise RuntimeError("bounded_cutoff_raw_quiet_plus_twenty_minutes:" + last_error)
            else:
                require(time.monotonic() < deadline, "wait_failed:" + description + ":" + last_error)

        return observe_until_ready(observe, check_exit, lambda: time.sleep(2))

    try:
        actual_head = command(["git", "rev-parse", "HEAD"], capture=True).strip()
        expected_head = command(["git", "rev-parse", args.expected_head + "^{commit}"], capture=True).strip()
        require(actual_head == expected_head, "declared_head_mismatch")
        summary["sourceHead"] = actual_head
        verify_checkout()
        if args.mode == "baseline":
            baseline_ref = command(["git", "rev-parse", "v0.0.124^{commit}"], capture=True).strip()
            if args.instrumentation_patch:
                require(args.expected_instrumentation_sha256, "instrumentation_digest_required")
                patch = args.instrumentation_patch.read_bytes()
                require(hashlib.sha256(patch).hexdigest() == args.expected_instrumentation_sha256,
                        "instrumentation_patch_digest_mismatch")
                actual_patch = command(["git", "diff", baseline_ref, actual_head], capture=True).encode()
                require(hashlib.sha256(actual_patch).hexdigest() == args.expected_instrumentation_sha256,
                        "baseline_instrumentation_diff_mismatch")
                summary["instrumentation"] = {"baselineRef": baseline_ref, "patchSHA256": args.expected_instrumentation_sha256}
            else:
                require(actual_head == baseline_ref, "baseline_not_v0.0.124")
        else:
            baseline = json.loads(args.baseline.read_text())
            validate_baseline(baseline, summary["fixtureFingerprint"], args.adopt_bounded_baseline_marker)
            summary["baselineAdoption"] = {"marker": args.adopt_bounded_baseline_marker, "status": baseline["status"]}
            summary["baselineTraceName"] = baseline["traceName"]
        identity = command(["/bin/bash", launcher, "--print-identity"], capture=True)
        (artifact / "debug-identity.env").write_text(identity)
        command(["/bin/bash", launcher, "--preflight-idle"])
        debug_processes = command(["ps", "-axo", "pid=,comm="], capture=True)
        require(not any(re.search(r"Agent\s*Studio Debug .*\.app/Contents/MacOS/AgentStudio$", line)
                        for line in debug_processes.splitlines()), "another_debug_app_running")
        # A short, private data root preserves Darwin's zmx socket path limit.
        runtime = Path(tempfile.mkdtemp(prefix="asw.v9.", dir=str(Path("/private/tmp").resolve()))).resolve()
        summary["runtimeRoot"] = str(runtime)
        fixture = runtime / "watched"
        repository = fixture / "repository"
        control_repository = fixture / "control"
        removed = fixture / "removed"
        created = fixture / "created"
        repository.mkdir(parents=True)
        command(["git", "init", repository])
        command(["git", "-C", repository, "config", "user.name", "AgentStudio V9 Fixture"])
        command(["git", "-C", repository, "config", "user.email", "v9@example.invalid"])
        command(["git", "-C", repository, "config", "commit.gpgsign", "false"])
        for index in range(args.files):
            directory = repository / ("files-%04d" % (index // 250))
            directory.mkdir(exist_ok=True)
            (directory / ("item-%06d.txt" % index)).write_text("fixture %d\n" % index)
        command(["git", "-C", repository, "add", "."], timeout=args.timeout)
        command(["git", "-C", repository, "commit", "-m", "V9 fixture"], timeout=args.timeout)
        command(["git", "-C", repository, "worktree", "add", "-b", "v9-removed", removed], timeout=args.timeout)
        command(["git", "init", control_repository])
        (control_repository / "README.md").write_text("V9 control repository\n")
        command(["git", "-C", control_repository, "add", "README.md"])
        command(["git", "-C", control_repository, "-c", "user.name=AgentStudio V9 Fixture",
                 "-c", "user.email=v9@example.invalid", "-c", "commit.gpgsign=false", "commit", "-m", "V9 control"])

        environment.update({"AGENTSTUDIO_OBSERVABILITY_STATE_FILE": str(state_file),
                            "AGENTSTUDIO_TRACE_NAME": trace, "AGENTSTUDIO_TRACE_TAGS": "performance,app.startup,terminal.startup",
                            "AGENTSTUDIO_TRACE_FLUSH": "immediate", "AGENTSTUDIO_TRACE_DIR": str(artifact / "traces"),
                            "AGENTSTUDIO_DEBUG_DATA_DIR": str(runtime / "data"),
                            "AGENTSTUDIO_IPC_DEBUG_TOKEN_ESCROW": str(artifact / "ipc-escrow.json"),
                            "AGENTSTUDIO_IPC_SOCKET_DIR": str(runtime / "data/ipc-socket"),
                            "AGENTSTUDIO_STARTUP_DIAGNOSTIC_ACTION": "add-watch-folder",
                            "AGENTSTUDIO_STARTUP_WATCH_FOLDER": str(fixture)})
        launch_attempted = True
        command(["mise", "run", "run-debug-observability", "--", "--detach"] + (["--skip-build"] if args.skip_build else []), timeout=3600)
        current = state()
        require(current["AGENTSTUDIO_OBSERVABILITY_STATUS"] == "running", "debug_launch_failed")
        require(current["AGENTSTUDIO_OBSERVABILITY_RUNTIME_FLAVOR"] == "debug", "not_debug_identity")
        require(current["AGENTSTUDIO_OBSERVABILITY_ZMX_DIR"] == str(runtime / "data/z"), "zmx_root_mismatch")
        require(current["AGENTSTUDIO_OBSERVABILITY_IPC_AUTH_MODE"] == "authenticated", "ipc_not_authenticated")
        executable = Path(current["AGENTSTUDIO_OBSERVABILITY_EXECUTABLE"])
        cli = executable.parent.parent / "Helpers/agentstudio"
        summary["buildIdentity"] = {key: value for key, value in current.items() if key not in ("AGENTSTUDIO_OBSERVABILITY_PROOF_TOKEN",)}
        summary["executableSHA256"] = hashlib.sha256(executable.read_bytes()).hexdigest()
        command(["/bin/bash", launcher, "--validate-candidate"])
        candidate_runtime_id = None
        metadata = json.loads((runtime / "data/ipc/runtime.json").read_text())
        identified = ipc("system.identify")
        require(identified.get("runtimeId") == metadata.get("runtimeId"), "candidate_ipc_identify_mismatch")
        candidate_runtime_id = metadata["runtimeId"]
        summary["validity"]["ipcRuntimeMatchesCandidate"] = True

        def membership(name, expected):
            readback = ipc("workspace.list")
            write_json(artifact / ("membership-" + name + ".json"), readback)
            paths = [worktree["path"] for workspace in readback["workspaces"]
                     for repo in workspace["repositories"] for worktree in repo["worktrees"]]
            return canonical_membership_matches(paths, expected)

        wait_for("initial_membership", lambda: membership("initial", [(repository, True), (removed, True), (control_repository, True)]))
        wait_for("initial_telemetry", lambda: records("ingress_snapshot") and records("logical_debt"))
        summary["validity"]["initialMembershipPublished"] = True
        summary["validity"]["preBurstMarkerTelemetryPresent"] = True
        summary["initialMembershipAndTelemetryPublishedAt"] = utc_now()
        if args.mode == "head":
            sample_arguments = ["/usr/bin/sample", current["AGENTSTUDIO_OBSERVABILITY_PID"], "10", "-file", str(artifact / "head-sample.txt")]
            with command_log.open("a") as output:
                output.write(shlex.join(sample_arguments) + "\n")
            with (artifact / "head-sample-command.log").open("w") as output:
                sample_process = subprocess.Popen(sample_arguments, stdout=output, stderr=subprocess.STDOUT)
            summary["supplementarySample"] = {"pid": sample_process.pid, "interpretation": "duration-weighted stack occupancy, not per-callback median"}
        action_monotonic = time.monotonic()
        action_start = time.time()
        summary["workloadHardCapSeconds"] = WORKLOAD_HARD_CAP_SECONDS
        summary["operationStart"] = utc_now()
        command(["git", "-C", repository, "worktree", "remove", removed], timeout=args.timeout)
        removal_finished = time.time()
        summary["removalFinished"] = utc_now()
        summary["validity"]["removalRetentionHeldByDesign"] = True
        creation_started = time.time()
        summary["creationStarted"] = utc_now()
        command(["git", "-C", repository, "worktree", "add", "-b", "v9-created", created], timeout=args.timeout)
        operations_finished = time.time()
        summary["creationFinished"] = utc_now()
        wait_for("creation_membership_not_published", lambda: membership("created", [(repository, True), (created, True)]))
        summary["validity"]["creationMembershipPublished"] = True
        summary["creationMembershipPublishedAt"] = utc_now()

        latest_selected = None
        bounded_cutoff = False

        def collect_completion():
            nonlocal latest_selected
            collected = {event: records(event) for event in EVENTS}
            require(collected["ingress_snapshot"] and
                    log_time(collected["ingress_snapshot"][-1]) >= operations_finished,
                    "final_ingress_snapshot_not_exported")
            selected = {event: [row for row in rows if log_time(row) >= action_start] for event, rows in collected.items()}
            ingress = collected["ingress_snapshot"]
            nonzero = [row for row in ingress if log_time(row) >= action_start and number(row, "ingress.local_raw_callback.event.count") > 0]
            summary["lastRawEventUnixSeconds"] = log_time(nonzero[-1]) if nonzero else action_start
            latest_selected = selected
            split = split_coarse_recoveries(selected["stage_outcome"])
            summary["watchedFolderCoarseRecoveries"] = split["watched_folder"]
            summary["worktreeCoarseRecoveries"] = split["worktree"]
            summary["coarseRecoveries"] = sum(row.get(PREFIX + "stage") == "overflow_recovery" and row.get(PREFIX + "outcome") == "overflow_coarse" for row in selected["stage_outcome"])
            summary["rawCallbackEvents"] = sum(number(row, "ingress.local_raw_callback.event.count") for row in selected["ingress_snapshot"])
            summary["rawCallbackBatches"] = sum(number(row, "ingress.local_raw_callback.batch.count") for row in selected["ingress_snapshot"])
            if args.mode == "head":
                validate_scan_record_shapes(collected["watched_scan_demand"], collected["watched_scan_run"], collected["watched_scan_obligation"])
                summary["r8ShapesChecked"] = {event: len(collected[event]) for event in EVENTS[:3]}
                debts = collected["logical_debt"]
                require(debts and PREFIX + "watched_folder.paced_pending.count" in debts[-1], "paced_pending_debt_telemetry_missing")
            compared = EVENTS[:4] if args.mode == "head" else ("stage_outcome",)
            summary["logMetricEventCounts"] = {event: event_count(event) for event in compared}
            for event, count in summary["logMetricEventCounts"].items():
                require(count == len(collected[event]), "logs_metrics_count_mismatch:" + event)
            total_split = split_coarse_recoveries(collected["stage_outcome"])
            summary["registrationKindMetricCounts"] = {kind: registration_kind_metric_count(kind) for kind in total_split}
            for kind, count in summary["registrationKindMetricCounts"].items():
                require(count == total_split[kind], "kind_logs_metrics_count_mismatch:" + kind)
            selected = {event: [row for row in rows if log_time(row) >= action_start]
                        for event, rows in collected.items()}
            if args.mode == "head":
                run_keys = {(row[SCAN + "folder_tag"], scan_number(row, "submission_sequence"))
                            for row in selected["watched_scan_run"]}
                demands = [row for row in collected["watched_scan_demand"]
                           if log_time(row) >= action_start or
                           (row[SCAN + "folder_tag"], scan_number(row, "submission_sequence")) in run_keys]
                evaluation = analyze_obligations(demands, selected["watched_scan_run"],
                                                  selected["watched_scan_obligation"])
                require(max(log_time(row) for row in selected["watched_scan_obligation"]) >= operations_finished,
                        "last_operation_obligation_not_closed")
                write_json(artifact / "obligation-joins.json", evaluation)
                summary.update(evaluation)
            # Debt is baseline closure and only a secondary head check; head also needs obligations.
            debt_settle(operations_finished, "final")
            summary["quietTail"] = quiet_tail_evidence(collected["ingress_snapshot"], action_start)
            summary["windowEnd"] = utc_now()
            return selected

        try:
            selected = wait_for("telemetry_window_completion", collect_completion, raw_quiet_cutoff=True)
        except RuntimeError as error:
            if not str(error).startswith("bounded_cutoff_raw_quiet_plus_twenty_minutes:") or latest_selected is None:
                raise
            bounded_cutoff = True
            cutoff = log_time({"_time": summary["boundedCutoffUTC"]})
            selected = {event: [row for row in records(event, end=cutoff) if log_time(row) >= action_start]
                        for event in EVENTS}
            summary["closureFailure"] = str(error)
            summary["windowEnd"] = summary["boundedCutoffUTC"]
            summary["quietTail"] = quiet_tail_evidence(selected["ingress_snapshot"], action_start)
        if args.mode == "head":
            summary["deliveryGapEstimates"] = [{
                "submissionSequence": scan_number(row, "submission_sequence"),
                "firstTriggerWallTimeEstimate": log_time(row) - scan_number(row, "obligation_wait_ms") / 1000
                                               + scan_number(row, "first_trigger_offset_ms") / 1000,
                "lastTriggerWallTimeEstimate": log_time(row) - scan_number(row, "obligation_wait_ms") / 1000
                                              + scan_number(row, "last_trigger_offset_ms") / 1000,
                "operationStartUnixSeconds": action_start,
                "operationsFinishedUnixSeconds": operations_finished,
                "qualification": "approximate wall-time projection from demand emission and monotonic offsets; exact offsets retained"
            } for row in selected["watched_scan_demand"] if row.get(SCAN + "reason") in CHANGE_REASONS]
        coarse = [row for row in selected["stage_outcome"]
                  if row.get(PREFIX + "stage") == "overflow_recovery"
                  and row.get(PREFIX + "outcome") == "overflow_coarse"]
        split = split_coarse_recoveries(selected["stage_outcome"])
        summary["watchedFolderCoarseRecoveries"] = split["watched_folder"]
        summary["worktreeCoarseRecoveries"] = split["worktree"]
        summary["coarseRecoveries"] = len(coarse)
        summary["phaseCoarseRecoveries"] = {
            "beforeCreationStart": sum(log_time(row) < creation_started for row in coarse),
            "fromCreationStartThroughClosure": sum(log_time(row) >= creation_started for row in coarse),
            "qualification": "time-split labels inside one window; delayed removal events may occur during creation phase"}
        summary["closureQualification"] = "observation cutoff after declared quiet tail; native delivery completeness unverified (no event-ID telemetry)"
        summary["cutoffBias"] = "baseline cutoff can undercount watched-folder coarse recoveries; head must reach strict closure; raw totals are context only"
        summary["rawCallbackEvents"] = sum(number(row, "ingress.local_raw_callback.event.count") for row in selected["ingress_snapshot"])
        summary["rawCallbackBatches"] = sum(number(row, "ingress.local_raw_callback.batch.count") for row in selected["ingress_snapshot"])
        require(summary["rawCallbackEvents"] > 0, "telemetry_window_empty")
        dropped = wait_for("trace_queue_completeness_metric", lambda: {
            "value": metric("agentstudio_performance_trace_queue_dropped_record_count")})["value"]
        summary["validity"]["traceQueueDroppedRecords"] = dropped
        require(dropped == 0, "telemetry_records_dropped")
        summary["validity"]["traceQueueHighWatermark"] = metric("agentstudio_performance_trace_queue_high_watermark")
        summary["validity"]["telemetryWindowPresent"] = True
        if args.mode == "baseline":
            summary["completedRuns"] = UNAVAILABLE
            summary["admittedTriggers"] = UNAVAILABLE
            summary["validity"]["baselineWatchedFolderCoarsePositive"] = summary["watchedFolderCoarseRecoveries"] > 0
            require(summary["watchedFolderCoarseRecoveries"] > 0, "baseline_no_watched_folder_coarse_recoveries")
            summary["status"] = "bounded_baseline_observation" if bounded_cutoff else "valid_baseline"
            summary["strictClosureReached"] = not bounded_cutoff
        else:
            summary["rawEventDifferencePercent"] = 100 * (summary["rawCallbackEvents"] / baseline["rawCallbackEvents"] - 1)
            summary["rawTotalsAreContextOnly"] = True
            summary["completedRuns"] = sum(row["completedRuns"] for row in summary.get("obligations", []))
            require(not bounded_cutoff, "head_strict_closure_not_reached")
            summary["completedRuns"] = sum(row["completedRuns"] for row in summary["obligations"])
            summary["watchedFolderCoarseReductionPercent"] = 100 * (1 - summary["watchedFolderCoarseRecoveries"] / baseline["watchedFolderCoarseRecoveries"])
            require(summary["watchedFolderCoarseRecoveries"] * 10 <= baseline["watchedFolderCoarseRecoveries"], "watched_folder_coarse_reduction_below_90_percent")
            summary["status"] = "supported_at_declared_head"
        require(command(["git", "rev-parse", "HEAD"], capture=True).strip() == actual_head, "target_changed_during_run")
        verify_checkout()
        summary["limits"] = ["cancelled runs without results", "owner real workspace", "other volumes",
                             "removal retained for 30 days; one window closes after creation publication plus debt log and two raw zero gauge exports; no baseline obligation record exists"]
    except Exception as error:
        summary["status"] = "invalid"
        summary["failureReason"] = str(error)
        raise
    finally:
        if sample_process is not None:
            try:
                summary["supplementarySample"]["exit"] = sample_process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                sample_process.terminate()
                summary["supplementarySample"]["exit"] = sample_process.wait(timeout=10)
                summary["supplementarySample"]["status"] = "sample exceeded its bound"
        write_json(artifact / "summary.json", summary)
        print(json.dumps(summary, indent=2, sort_keys=True), flush=True)
        if launch_attempted and state_file.exists():
            try:
                command(["/bin/bash", launcher, "--retire-candidate"], timeout=60)
                environment["ZMX_DIR"] = str(runtime / "data/z")
                zmx = runtime / "data/bin/zmx"
                inventory = command([zmx, "list"], capture=True, timeout=10)
                (artifact / "zmx-inventory.txt").write_text(inventory)
                session_ids = re.findall(r"^\s*(?:session_name|name)=(\S+)", inventory, re.MULTILINE)
                if session_ids:
                    command(["/bin/bash", target / "scripts/cleanup-owned-zmx-sessions.sh",
                             zmx, runtime / "data/z", artifact / "zmx-cleanup.env"] + session_ids, timeout=30)
                require(runtime.parent == Path("/private/tmp") and runtime.name.startswith("asw.v9.")
                        and not (runtime / "watched").is_symlink(), "fixture_cleanup_ownership_mismatch")
                shutil.rmtree(runtime / "watched")
                require(not (runtime / "watched").exists(), "fixture_cleanup_incomplete")
                summary["cleanup"] = "verified: owned debug candidate retired, isolated zmx sessions removed, fixture removed"
                summary["retainedRuntimeRoot"] = str(runtime)
            except Exception as error:
                summary["cleanup"] = "held: " + str(error)
                summary["status"] = "invalid"
            write_json(artifact / "summary.json", summary)
        elif runtime:
            summary["cleanup"] = "fixture retained; no launched app"
            write_json(artifact / "summary.json", summary)
    require(str(summary.get("cleanup", "")).startswith("verified:"), "cleanup_unverified")


try:
    main()
except Exception as error:
    print("FAIL: " + str(error), file=sys.stderr)
    sys.exit(1)
PY
