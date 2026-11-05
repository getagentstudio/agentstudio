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


def canonical_membership_matches(paths, expected):
    canonical_paths = {str(Path(path).resolve()) for path in paths}
    return all((str(path.resolve()) in canonical_paths) == present for path, present in expected)


def analyze_obligations(demands, runs, closures):
    require(closures, "obligation_closure_missing")
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
    print("driver self-test: 13 passed, 0 failed; no app, fixture or network")


def main():
    parser = argparse.ArgumentParser(description="V9 watched-folder burst journey; Victoria evidence only.")
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--target-root", type=Path, default=Path(sys.argv[1]))
    parser.add_argument("--expected-head", help="Required exact source commit for the launched debug build")
    parser.add_argument("--mode", choices=("baseline", "head"), default="head")
    parser.add_argument("--baseline", type=Path, help="Valid baseline summary.json; required for head mode")
    parser.add_argument("--proof-root", type=Path, default=Path(tempfile.gettempdir()) / "watched-folder-v9")
    parser.add_argument("--files", type=int, default=150000)
    parser.add_argument("--timeout", type=int, default=600, help="Hang bound; never a scan-count budget")
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
    environment = os.environ.copy()
    launcher = target / "scripts/run-debug-observability.sh"
    state_file = artifact / "debug-observability.env"
    command_log = artifact / "commands.log"

    def command(arguments, *, capture=False, cwd=target, timeout=120):
        with command_log.open("a") as output:
            output.write(shlex.join(str(value) for value in arguments) + "\n")
        result = subprocess.run([str(value) for value in arguments], cwd=cwd, env=environment,
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
        with (artifact / "queries.log").open("a") as output:
            output.write(kind + " " + expression + " " + json.dumps(parameters) + "\n")
        parameters["query"] = expression
        with urllib.request.urlopen(urls[kind] + "?" + urllib.parse.urlencode(parameters), timeout=15) as response:
            return response.read().decode()

    marker = '{service.name="AgentStudio",dev.runtime.flavor="debug"} agent.proof.marker:=' + json.dumps(trace)

    def records(event):
        expression = marker + ' _msg:=' + json.dumps("performance.filesystem." + event)
        response = query("logs", expression + " | sort by (_time) | limit 200000")
        rows = [json.loads(line) for line in response.splitlines() if line.strip()]
        count_response = query("logs", expression + " | stats count() as records")
        counts = [json.loads(line) for line in count_response.splitlines() if line.strip()]
        require(len(counts) == 1 and int(counts[0]["records"]) == len(rows), "telemetry_query_truncated:" + event)
        (artifact / (event + ".ndjson")).write_text(response)
        return rows

    def metric(name):
        expression = 'max(' + name + '{service.name="AgentStudio",dev.runtime.flavor="debug",agent.proof.marker=' + json.dumps(trace) + '})'
        response = json.loads(query("metrics", expression, latency_offset="0"))
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
        response = json.loads(query("metrics", expression, latency_offset="0"))
        write_json(artifact / (event + "-counter.json"), response)
        require(response.get("status") == "success", "metrics_event_count_failed:" + event)
        rows = response["data"]["result"]
        return float(rows[0]["value"][1]) if len(rows) == 1 else 0

    def ipc(method):
        result = json.loads(command([cli, method], capture=True, timeout=15))
        require("error" not in result, "ipc_error:" + method)
        return result.get("result", result)

    def wait_for(description, observe):
        deadline = time.monotonic() + args.timeout
        last_error = "no matching observation"
        while True:
            if launch_attempted and state_file.exists():
                current = state()
                if current.get("AGENTSTUDIO_OBSERVABILITY_STATUS") == "running":
                    try:
                        os.kill(int(current["AGENTSTUDIO_OBSERVABILITY_PID"]), 0)
                    except ProcessLookupError:
                        raise RuntimeError("debug_app_retired_while_waiting:" + description)
            try:
                result = observe()
                if result:
                    return result
            except (RuntimeError, OSError, ValueError, KeyError) as error:
                last_error = str(error)
            require(time.monotonic() < deadline, "wait_failed:" + description + ":" + last_error)
            time.sleep(2)

    try:
        actual_head = command(["git", "rev-parse", "HEAD"], capture=True).strip()
        expected_head = command(["git", "rev-parse", args.expected_head + "^{commit}"], capture=True).strip()
        require(actual_head == expected_head, "declared_head_mismatch")
        summary["sourceHead"] = actual_head
        verify_checkout()
        if args.mode == "baseline":
            require(actual_head == command(["git", "rev-parse", "v0.0.124^{commit}"], capture=True).strip(), "baseline_not_v0.0.124")
        else:
            baseline = json.loads(args.baseline.read_text())
            require(baseline.get("status") == "valid_baseline", "baseline_invalid")
            require(baseline["fixtureFingerprint"] == summary["fixtureFingerprint"], "baseline_fixture_mismatch")
            require(baseline["coarseRecoveries"] > 0, "baseline_no_coarse_recoveries")
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

        def membership(name, expected):
            readback = ipc("workspace.list")
            write_json(artifact / ("membership-" + name + ".json"), readback)
            paths = [worktree["path"] for workspace in readback["workspaces"]
                     for repo in workspace["repositories"] for worktree in repo["worktrees"]]
            return canonical_membership_matches(paths, expected)

        wait_for("initial_membership", lambda: membership("initial", [(repository, True), (removed, True), (control_repository, True)]))
        wait_for("initial_telemetry", lambda: records("ingress_snapshot") and records("logical_debt"))
        summary["validity"]["initialMembershipPublished"] = True
        action_start = time.time()
        summary["operationStart"] = utc_now()
        command(["git", "-C", repository, "worktree", "remove", removed], timeout=args.timeout)
        summary["removalFinished"] = utc_now()
        wait_for("removal_membership_not_published", lambda: membership("removed", [(removed, False), (repository, True)]))
        summary["validity"]["removalMembershipPublished"] = True
        summary["removalMembershipPublishedAt"] = utc_now()
        command(["git", "-C", repository, "worktree", "add", "-b", "v9-created", created], timeout=args.timeout)
        operations_finished = time.time()
        summary["creationFinished"] = utc_now()
        wait_for("creation_membership_not_published", lambda: membership("created", [(removed, False), (created, True)]))
        summary["validity"]["creationMembershipPublished"] = True
        summary["creationMembershipPublishedAt"] = utc_now()

        def collect_completion():
            collected = {event: records(event) for event in EVENTS}
            compared = EVENTS[:4] if args.mode == "head" else ("stage_outcome",)
            summary["logMetricEventCounts"] = {event: event_count(event) for event in compared}
            for event, count in summary["logMetricEventCounts"].items():
                require(count == len(collected[event]), "logs_metrics_count_mismatch:" + event)
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
            else:
                # Baseline has no obligation lifecycle. Retain its explicit observation boundary;
                # never infer run counts from debt transitions or recovery records.
                debts = [row for row in collected["logical_debt"] if log_time(row) >= int(operations_finished)]
                require(debts and number(debts[-1], "logical_debt.count") == 0, "baseline_final_debt_not_zero")
            summary["windowEnd"] = utc_now()
            return selected

        selected = wait_for("telemetry_window_completion", collect_completion)
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
        summary["coarseRecoveries"] = len(coarse)
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
            summary["validity"]["baselineCoarseRecoveriesPositive"] = len(coarse) > 0
            require(coarse, "baseline_no_coarse_recoveries")
            summary["status"] = "valid_baseline"
        else:
            summary["completedRuns"] = sum(row["completedRuns"] for row in summary["obligations"])
            summary["coarseRecoveryReductionPercent"] = 100 * (1 - len(coarse) / baseline["coarseRecoveries"])
            require(len(coarse) * 10 <= baseline["coarseRecoveries"], "coarse_recovery_reduction_below_90_percent")
            summary["status"] = "supported_at_declared_head"
        require(command(["git", "rev-parse", "HEAD"], capture=True).strip() == actual_head, "target_changed_during_run")
        verify_checkout()
        summary["limits"] = ["cancelled runs without results", "owner real workspace", "other volumes",
                             "baseline ends at published membership and fresh zero debt; no baseline obligation record exists"]
    except Exception as error:
        summary["status"] = "invalid"
        summary["failureReason"] = str(error)
        raise
    finally:
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
