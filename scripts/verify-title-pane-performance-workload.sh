#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
METRICS_QUERY_URL="${AI_TOOLS_OBSERVABILITY_METRICS_QUERY_URL:-http://127.0.0.1:8428/api/v1/query}"
LOGS_QUERY_URL="${AI_TOOLS_OBSERVABILITY_LOGS_QUERY_URL:-http://127.0.0.1:9428/select/logsql/query}"
WORKLOAD_TRACE_TAGS="${AGENTSTUDIO_TRACE_TAGS:-performance,atoms,app.startup,terminal.startup}"

validate_fixture() {
  /usr/bin/python3 - "$1" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    proof = json.load(stream)
records = proof["drainRecords"]
by_class = {record["drainClass"]: record for record in records}
for drain_class in ("immediate", "title_deadline", "exact_barrier"):
    if drain_class not in by_class:
        print(f"missing {drain_class} drain", file=sys.stderr)
        raise SystemExit(1)
deadline = by_class["title_deadline"]["elapsedMilliseconds"]
if deadline > 1000:
    print("title_deadline queue age exceeded 1000ms", file=sys.stderr)
    raise SystemExit(1)
metric = proof.get("titleDeadlineMetricMilliseconds")
if metric is None:
    print("missing title_deadline Victoria metric", file=sys.stderr)
    raise SystemExit(1)
ipc = proof["ipc"]
if not ipc["titleReadbackSucceeded"]:
    print("terminal title readback did not advance", file=sys.stderr)
    raise SystemExit(1)
if not ipc["titleWaitSucceeded"] or not ipc["commandFinishedWaitSucceeded"]:
    print("terminal title wait did not succeed", file=sys.stderr)
    raise SystemExit(1)
immediate_time = by_class["immediate"]["timeUnixNanoseconds"]
if not ipc["workloadStartUnixNanoseconds"] <= immediate_time <= ipc["workloadEndUnixNanoseconds"]:
    print("immediate activity drain was not inside pending title interval", file=sys.stderr)
    raise SystemExit(1)
rendered = proof["renderedOTLP"]
if any(value and value in rendered for value in proof["sensitiveValues"]):
    print("sensitive terminal content survived OTLP projection", file=sys.stderr)
    raise SystemExit(1)
pane = proof["pane"]
equal_title = proof["equalTitlePhase"]
if equal_title["offerCount"] != 20:
    print("equal-title phase must offer exactly 20 titles", file=sys.stderr)
    raise SystemExit(1)
admitted_equal_count = equal_title["equalSuppressedCount"] + equal_title["scheduledTitleDrainCount"]
if admitted_equal_count < 10:
    print(
        f"stimulus_invalid: equal-title phase admitted fewer than 10 equal offers: admitted_equal={admitted_equal_count}",
        file=sys.stderr,
    )
    raise SystemExit(1)
ratio_failures = []
if equal_title["equalSuppressedCount"] * 10 < admitted_equal_count * 9:
    ratio_failures.append("equal-title phase suppressed less than 90% of admitted equal offers")
if equal_title["scheduledTitleDrainCount"] * 10 > admitted_equal_count:
    ratio_failures.append("equal-title phase drained more than 10% of admitted equal offers")
if ratio_failures:
    print("; ".join(ratio_failures), file=sys.stderr)
    raise SystemExit(1)
if equal_title["canonicalAcceptedMutationDelta"] > equal_title["offerCount"]:
    print("equal-title phase canonical mutations exceeded driver sends", file=sys.stderr)
    raise SystemExit(1)
if pane["tabBarAffectedItemCount"] != 1:
    print("tabbar affected-item count must be 1", file=sys.stderr)
    raise SystemExit(1)
if any(pane[key] != 0 for key in (
    "titleRepoProjectionDelta",
    "titleRepoCommandEventDelta",
    "titleRepoCommandResolutionDelta",
    "titleRepoCapabilitySnapshotDelta",
    "titleStructuralAcceptedMutationDelta",
)):
    print("title mutation performed structural or Repo command work", file=sys.stderr)
    raise SystemExit(1)
if pane["titleCanonicalAcceptedMutationDelta"] != 1:
    print("title mutation did not accept exactly one canonical pane change", file=sys.stderr)
    raise SystemExit(1)
if not 1 <= pane["paneStructuralCanonicalAcceptedMutationDelta"] <= 8:
    print("pane structural phase canonical work was not bounded", file=sys.stderr)
    raise SystemExit(1)
if not 1 <= pane["paneStructuralAcceptedMutationDelta"] <= 8:
    print("pane structural phase structural work was not bounded", file=sys.stderr)
    raise SystemExit(1)
if not 1 <= pane["paneMembershipAcceptedMutationDelta"] <= 8:
    print("pane structural phase membership work was not bounded", file=sys.stderr)
    raise SystemExit(1)
if pane["capabilityRepoCommandEventDelta"] != 1 or pane["capabilityRepoAffectedItemCount"] <= 0:
    print("missing capability-driven Repo Explorer command refresh", file=sys.stderr)
    raise SystemExit(1)
if not 1 <= pane["capabilityRepoCommandResolutionCount"] == pane["capabilityVisibleRequestCount"]:
    print("unbounded command resolutions", file=sys.stderr)
    raise SystemExit(1)
if pane["capabilityRepoCapabilitySnapshotCount"] != 1:
    print("capability snapshots per refresh must be 1", file=sys.stderr)
    raise SystemExit(1)
if pane["capabilityTabBarAffectedItemCount"] != 0:
    print("capability phase affected unrelated tab items", file=sys.stderr)
    raise SystemExit(1)
print("title and pane performance proof ok")
PY
}

case "${1:-}" in
  --validate-fixture)
    [ "$#" -eq 2 ] || { echo "missing fixture path" >&2; exit 2; }
    validate_fixture "$2"
    exit 0
    ;;
  --proof) ;;
  *) echo "usage: $0 --proof | --validate-fixture FILE" >&2; exit 2 ;;
esac

if [ -n "${AGENTSTUDIO_IPC_UNSAFE_NO_AUTH:-}" ]; then
  echo "title/pane proof refuses AGENTSTUDIO_IPC_UNSAFE_NO_AUTH" >&2
  exit 2
fi
TRACE_NAME="${AGENTSTUDIO_TRACE_NAME:-title-pane-$(date +%Y%m%d%H%M%S)-$$}"
case "$TRACE_NAME" in ""|*/*|*\\*|*[!A-Za-z0-9_.-]*) echo "unsafe AGENTSTUDIO_TRACE_NAME" >&2; exit 2;; esac
TRACE_NONCE="$(/usr/bin/uuidgen)"
TRACE_MARKER="$(printf '%s:%s' "$TRACE_NAME" "$TRACE_NONCE" | /usr/bin/shasum -a 256 | awk '{print "title-pane-" substr($1,1,20)}')"
PROOF_ROOT="${AGENTSTUDIO_TITLE_PANE_PROOF_ROOT:-/tmp/agentstudio-title-pane-performance}"
ARTIFACT="$PROOF_ROOT/$TRACE_NAME"
STATE_FILE="${AGENTSTUDIO_OBSERVABILITY_STATE_FILE:-$ARTIFACT/debug-observability.env}"
APP_PID=""
mkdir -p "$ARTIFACT" "$(dirname "$STATE_FILE")"
IPC_DEBUG_ESCROW_PATH="$(/usr/bin/python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$ARTIFACT/ipc-escrow.json")"

decode_state() {
  local raw
  raw="$(sed -n "s/^$1=//p" "$STATE_FILE" | tail -1)"
  /usr/bin/python3 - "$raw" <<'PY'
import shlex, sys
parts = shlex.split(sys.argv[1]) if sys.argv[1] else []
print(parts[0] if parts else "")
PY
}

ipc_runtime_matches_app_pid() {
  /usr/bin/python3 - "$1" "$2" "$3" <<'PY'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as stream:
        runtime = json.load(stream)
    expected_pid = int(sys.argv[2])
    with open(sys.argv[3], encoding="utf-8") as stream:
        escrow = json.load(stream)
except (OSError, TypeError, ValueError, json.JSONDecodeError):
    raise SystemExit(1)
matches = (
    runtime.get("processIdentifier") == expected_pid
    and bool(escrow.get("runtimeId"))
    and escrow.get("runtimeId") == runtime.get("runtimeId")
    and bool(escrow.get("socketPath"))
    and escrow.get("socketPath") == runtime.get("socketPath")
    and isinstance(escrow.get("token"), str) and bool(escrow["token"])
)
raise SystemExit(0 if matches else 1)
PY
}

stop_pid() {
  local pid="$1"
  [ -n "$pid" ] || return 0
  if kill -0 "$pid" >/dev/null 2>&1; then
    kill "$pid" >/dev/null 2>&1 || true
    wait "$pid" >/dev/null 2>&1 || true
  fi
}

cleanup() {
  local cleanup_pid="$APP_PID"
  if [ -z "$cleanup_pid" ] && [ -f "$STATE_FILE" ] \
    && [ "$(decode_state AGENTSTUDIO_OBSERVABILITY_MARKER)" = "$TRACE_MARKER" ]
  then
    cleanup_pid="$(decode_state AGENTSTUDIO_OBSERVABILITY_PID)"
  fi
  case "$cleanup_pid" in
    ''|*[!0-9]*) return 0 ;;
  esac
  stop_pid "$cleanup_pid"
}

trap cleanup EXIT INT TERM

query_value() {
  local response
  response="$(/usr/bin/curl --fail --silent --show-error --max-time 10 --get --data-urlencode "query=$1" "$METRICS_QUERY_URL")"
  /usr/bin/python3 - "$response" <<'PY'
import json, sys
data = json.loads(sys.argv[1]).get("data", {}).get("result", [])
values = []
for item in data:
    try: values.append(float(item["value"][1]))
    except (KeyError, IndexError, TypeError, ValueError): pass
print(max(values) if values else 0)
PY
}

decode_identity() {
  local raw
  raw="$(printf '%s\n' "$RESET_IDENTITY" | sed -n "s/^$1=//p" | tail -1)"
  /usr/bin/python3 - "$raw" <<'PY'
import shlex, sys
parts = shlex.split(sys.argv[1]) if sys.argv[1] else []
print(parts[0] if parts else "")
PY
}

reset_disposable_debug_root() {
  local expected_bundle_identifier zmx_pid zmx_pids
  RESET_IDENTITY="$("$PROJECT_ROOT/scripts/run-debug-observability.sh" --print-identity)"
  RESET_DEBUG_CODE="$(decode_identity AGENTSTUDIO_OBSERVABILITY_DEBUG_CODE)"
  RESET_DATA_DIR="$(decode_identity AGENTSTUDIO_OBSERVABILITY_DATA_DIR)"
  RESET_BUNDLE_IDENTIFIER="$(decode_identity AGENTSTUDIO_OBSERVABILITY_BUNDLE_IDENTIFIER)"

  case "$RESET_DATA_DIR" in
    "$HOME/.agentstudio-db/"*) ;;
    *) echo "refusing to reset debug data root outside $HOME/.agentstudio-db/: $RESET_DATA_DIR" >&2; exit 1 ;;
  esac
  [ "$RESET_DATA_DIR" != "$HOME/.agentstudio-db" ] || {
    echo "refusing to reset debug data root container" >&2
    exit 1
  }
  case "$RESET_DEBUG_CODE" in
    ''|*[!a-z0-9]*) echo "refusing reset with unsafe debug code: $RESET_DEBUG_CODE" >&2; exit 1 ;;
  esac
  expected_bundle_identifier="com.agentstudio.app.debug.d$RESET_DEBUG_CODE"
  if [ "$RESET_BUNDLE_IDENTIFIER" != "$expected_bundle_identifier" ]; then
    echo "refusing reset for mismatched debug bundle identifier: $RESET_BUNDLE_IDENTIFIER" >&2
    exit 1
  fi

  "$PROJECT_ROOT/scripts/run-debug-observability.sh" --preflight-idle
  zmx_pids="$(/bin/ps -axo pid=,command= | /usr/bin/python3 -c '
import os, shlex, sys
data_dir = sys.argv[1]
for line in sys.stdin:
    process_fields = line.strip().split(maxsplit=1)
    if len(process_fields) != 2 or not process_fields[0].isdigit():
        continue
    command = process_fields[1]
    try:
        command_parts = shlex.split(command)
    except ValueError:
        continue
    if not command_parts or os.path.basename(command_parts[0]) != "zmx":
        continue
    if data_dir not in command:
        continue
    print(process_fields[0])
' "$RESET_DATA_DIR")"

  for zmx_pid in $zmx_pids; do
    kill "$zmx_pid"
  done
  for _ in $(seq 1 40); do
    local live_zmx_pid=""
    for zmx_pid in $zmx_pids; do
      if kill -0 "$zmx_pid" >/dev/null 2>&1; then
        live_zmx_pid="$zmx_pid"
        break
      fi
    done
    [ -z "$live_zmx_pid" ] && break
    /bin/sleep 0.25
  done
  for zmx_pid in $zmx_pids; do
    if kill -0 "$zmx_pid" >/dev/null 2>&1; then
      kill -KILL "$zmx_pid"
    fi
  done
  for _ in $(seq 1 20); do
    local live_zmx_pid=""
    for zmx_pid in $zmx_pids; do
      if kill -0 "$zmx_pid" >/dev/null 2>&1; then
        live_zmx_pid="$zmx_pid"
        break
      fi
    done
    [ -z "$live_zmx_pid" ] && break
    /bin/sleep 0.25
  done
  for zmx_pid in $zmx_pids; do
    if kill -0 "$zmx_pid" >/dev/null 2>&1; then
      echo "refusing to remove debug data root while zmx remains live: pid=$zmx_pid data_dir=$RESET_DATA_DIR" >&2
      exit 1
    fi
  done

  echo "title/pane reset: bundle_id=$RESET_BUNDLE_IDENTIFIER data_dir=$RESET_DATA_DIR zmx_pids=${zmx_pids:-none}"
  /bin/rm -rf -- "$RESET_DATA_DIR"
}

RESET_IDENTITY=""
RESET_DEBUG_CODE=""
RESET_DATA_DIR=""
RESET_BUNDLE_IDENTIFIER=""
reset_disposable_debug_root

env \
  AGENTSTUDIO_TRACE_TAGS="$WORKLOAD_TRACE_TAGS" \
  AGENTSTUDIO_TRACE_NAME="$TRACE_MARKER" \
  AGENTSTUDIO_IPC_DEBUG_TOKEN_ESCROW="$IPC_DEBUG_ESCROW_PATH" \
  AGENTSTUDIO_STARTUP_DIAGNOSTIC_ACTION=sidebar-performance-proof \
  AGENTSTUDIO_OBSERVABILITY_STATE_FILE="$STATE_FILE" \
  "$PROJECT_ROOT/scripts/run-debug-observability.sh" --detach
for _ in $(seq 1 60); do
  [ -f "$STATE_FILE" ] && [ "$(decode_state AGENTSTUDIO_OBSERVABILITY_STATUS)" = running ] && break
  /bin/sleep 1
done
[ "$(decode_state AGENTSTUDIO_OBSERVABILITY_STATUS)" = running ] || { echo "debug app did not start" >&2; exit 1; }
[ "$(decode_state AGENTSTUDIO_OBSERVABILITY_IPC_AUTH_MODE)" = authenticated ] || { echo "authenticated IPC required" >&2; exit 1; }
[ "$(decode_state AGENTSTUDIO_OBSERVABILITY_MARKER)" = "$TRACE_MARKER" ] || { echo "debug app marker mismatch" >&2; exit 1; }
APP_PID="$(decode_state AGENTSTUDIO_OBSERVABILITY_PID)"
case "$APP_PID" in
  ''|*[!0-9]*) echo "debug app state missing numeric PID" >&2; exit 1 ;;
esac
DATA_DIR="$(decode_state AGENTSTUDIO_OBSERVABILITY_DATA_DIR)"
IPC_RUNTIME_FILE="$DATA_DIR/ipc/runtime.json"
IPC_READINESS_ATTEMPTS=80
METRIC_EXPORT_ATTEMPTS=45
ipc_readiness_attempt=0
while [ "$ipc_readiness_attempt" -lt "$IPC_READINESS_ATTEMPTS" ]; do
  if [ -s "$IPC_DEBUG_ESCROW_PATH" ] \
    && ipc_runtime_matches_app_pid "$IPC_RUNTIME_FILE" "$APP_PID" "$IPC_DEBUG_ESCROW_PATH"
  then
    break
  fi
  ipc_readiness_attempt=$((ipc_readiness_attempt + 1))
  /bin/sleep 0.25
done
if [ ! -s "$IPC_DEBUG_ESCROW_PATH" ] \
  || ! ipc_runtime_matches_app_pid "$IPC_RUNTIME_FILE" "$APP_PID" "$IPC_DEBUG_ESCROW_PATH"
then
  echo "authenticated IPC for the launched PID did not become ready before timeout: AGENTSTUDIO_IPC_DEBUG_TOKEN_ESCROW=$IPC_DEBUG_ESCROW_PATH" >&2
  exit 1
fi

/usr/bin/python3 - "$IPC_RUNTIME_FILE" "$IPC_DEBUG_ESCROW_PATH" "$LOGS_QUERY_URL" "$TRACE_MARKER" <<'PY'
import datetime, json, socket, sys, time, urllib.parse, urllib.request, uuid
with open(sys.argv[1], encoding="utf-8") as stream: socket_path = json.load(stream)["socketPath"]
with open(sys.argv[2], encoding="utf-8") as stream: escrow = json.load(stream)
if escrow.get("socketPath") != socket_path:
    raise SystemExit("AGENTSTUDIO_IPC_DEBUG_TOKEN_ESCROW does not match IPC metadata")
token = escrow["token"]
logs_url, marker = sys.argv[3:5]
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); sock.settimeout(20); sock.connect(socket_path)
reader = sock.makefile("rb"); request_id = 0
def request(method, params):
    global request_id
    request_id += 1
    sock.sendall((json.dumps({"jsonrpc":"2.0","id":request_id,"method":method,"params":params}, separators=(",",":"))+"\n").encode())
    while True:
        line = reader.readline()
        if not line: raise RuntimeError(f"socket closed during {method}")
        response = json.loads(line)
        if response.get("id") == request_id:
            if response.get("error") is not None: raise RuntimeError(f"{method}: {response['error']}")
            return response.get("result", {})
def marker_records():
    query = f'agent.proof.marker:="{marker}"'
    url = logs_url + "?" + urllib.parse.urlencode({"query": query})
    with urllib.request.urlopen(url, timeout=10) as response:
        lines = response.read().decode().splitlines()
    records = []
    for line in lines:
        if not line.strip(): continue
        decoded = json.loads(line)
        records.extend(decoded if isinstance(decoded, list) else [decoded])
    return records
def numeric(record, key):
    try: return int(float(record.get(key, 0)))
    except (TypeError, ValueError): return 0
def snapshot():
    records = marker_records()
    repo = [record for record in records if record.get("_msg") == "performance.repo_explorer.command_presentation"]
    tab = [record for record in records if record.get("_msg") == "performance.tabbar.refresh"]
    atom_mutations = [record for record in records if record.get("_msg") == "performance.atom.mutation"]
    canonical = [record for record in atom_mutations if record.get("agentstudio.performance.atom.label") == "pane_graph_canonical"]
    structural = [record for record in atom_mutations if record.get("agentstudio.performance.atom.label") == "pane_graph_structural"]
    terminal_drains = [record for record in records if record.get("_msg") == "performance.terminal.accumulator_drain"]
    equal_suppressions = [record for record in records if record.get("_msg") == "performance.terminal.equal_suppressed"]
    return {
        "repo_events": len(repo),
        "repo_affected": sum(numeric(record, "agentstudio.performance.repo_explorer.affected_item.count") for record in repo),
        "repo_resolutions": sum(numeric(record, "agentstudio.performance.repo_explorer.command_resolution.count") for record in repo),
        "repo_capability_snapshots": sum(numeric(record, "agentstudio.performance.repo_explorer.capability_snapshot.count") for record in repo),
        "repo_projection": sum(1 for record in records if record.get("_msg") == "performance.sidebar.projection" and record.get("agentstudio.performance.sidebar.surface") == "repo"),
        "tab_affected": sum(numeric(record, "agentstudio.performance.tabbar.affected_item.count") for record in tab),
        "canonical_accepted": sum(numeric(record, "agentstudio.performance.atom.accepted_change.count") for record in canonical),
        "structural_accepted": sum(numeric(record, "agentstudio.performance.atom.accepted_change.count") for record in structural),
        "membership_accepted": sum(numeric(record, "agentstudio.performance.atom.accepted_change.count") for record in structural if record.get("agentstudio.performance.atom.operation") in ("set", "remove")),
        "scheduled_title_drains": sum(
            numeric(record, "agentstudio.performance.terminal.accumulator.scheduled_drain.count")
            for record in terminal_drains
            if record.get("agentstudio.performance.terminal.accumulator.drain.class") == "title_deadline"
        ),
        "title_apply_equal": sum(
            1 for record in terminal_drains
            if record.get("agentstudio.performance.terminal.accumulator.apply.outcome") == "equal"
        ),
        "title_apply_changed": sum(
            1 for record in terminal_drains
            if record.get("agentstudio.performance.terminal.accumulator.apply.outcome") == "changed"
        ),
        "equal_title_suppressed": sum(
            numeric(record, "agentstudio.performance.terminal.equal_suppressed.count")
            for record in equal_suppressions
            if record.get("agentstudio.performance.terminal.publication.kind") == "title"
        ),
    }
def delta(before, after):
    return {key: after[key] - before[key] for key in before}
def wait_for_delta(before, predicate, description, timeout=20):
    deadline = time.monotonic() + timeout
    latest = delta(before, snapshot())
    while time.monotonic() < deadline:
        if predicate(latest): return latest
        time.sleep(0.25)
        latest = delta(before, snapshot())
    raise RuntimeError(f"timed out waiting for {description}: {latest}")
def quiescent_snapshot(timeout=10):
    deadline = time.monotonic() + timeout
    previous = snapshot()
    stable_samples = 0
    while time.monotonic() < deadline:
        time.sleep(0.25)
        current = snapshot()
        if current == previous:
            stable_samples += 1
            if stable_samples == 4: return current
        else:
            stable_samples = 0
        previous = current
    raise RuntimeError(f"performance records did not quiesce: {previous}")
def wait_for_terminal_pane(timeout=20):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        panes = request("pane.list", {}).get("panes", [])
        pane = next((item for item in panes if item.get("contentKind") == "terminal"), None)
        if pane is not None: return pane
        time.sleep(0.25)
    raise RuntimeError("timed out waiting for sidebar-performance-proof terminal")
def wait_for_startup_diagnostic_completion(timeout=20):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        records = marker_records()
        if any(record.get("_msg") == "app.startup_diagnostic_action.completed" for record in records):
            return
        if any(record.get("_msg") == "app.startup_diagnostic_action.blocked" for record in records):
            raise RuntimeError("startup diagnostic reported blocked")
        time.sleep(0.25)
    raise RuntimeError("timed out waiting for startup diagnostic completion")
def record_time_ns(record):
    timestamp = str(record.get("_time", "")).replace("Z", "+00:00")
    parsed = datetime.datetime.strptime(timestamp, "%Y-%m-%dT%H:%M:%S.%f%z")
    return int(parsed.timestamp() * 1_000_000_000)
def latest_repo_sort_projection():
    matching = [
        record for record in marker_records()
        if record.get("_msg") == "performance.sidebar.projection"
        and record.get("agentstudio.performance.sidebar.surface") == "repo"
        and record.get("agentstudio.performance.sidebar.phase") == "projection_worker"
        and record.get("agentstudio.performance.sidebar.sort_order") in {"ascending", "descending"}
    ]
    if not matching: return None
    return max(matching, key=record_time_ns)
def wait_for_repo_sort_projection(expected_order=None, after_ns=0, timeout=10):
    deadline = time.monotonic() + timeout
    latest = None
    while time.monotonic() < deadline:
        latest = latest_repo_sort_projection()
        if latest is not None:
            order = latest.get("agentstudio.performance.sidebar.sort_order")
            if record_time_ns(latest) > after_ns and (expected_order is None or order == expected_order):
                return latest
        time.sleep(0.25)
    raise RuntimeError(
        f"timed out waiting for completed repo sort projection order={expected_order}: {latest}"
    )
request("auth.login", {"token":token})
windows = request("window.list", {}).get("windows", [])
if len(windows) != 1:
    raise RuntimeError(f"title/pane proof requires exactly one workspace window; got {len(windows)}")
workspace_window_arguments = {"workspaceWindowId": str(uuid.UUID(windows[0]["id"]))}
show_repos_result = request(
    "command.execute",
    {"commandId":"showReposSidebar","correlationId":str(uuid.uuid4()),"arguments":workspace_window_arguments},
)
# IPCCommandExecutionResult.swift:204 encodes the kind discriminator.
if show_repos_result.get("kind") != "applied":
    raise RuntimeError(f"showReposSidebar did not apply: {show_repos_result}")
pane = wait_for_terminal_pane()
wait_for_startup_diagnostic_completion()
# IPCTargetSelector.swift:19-21 uses bare UUIDs for canonical selectors.
handle = pane["id"]
initial_sort_projection = wait_for_repo_sort_projection()
initial_sort_order = initial_sort_projection["agentstudio.performance.sidebar.sort_order"]
first_sort_toggle_result = request(
    "command.execute",
    {
        "commandId":"toggleReposSortDirection",
        "correlationId":str(uuid.uuid4()),
        "arguments":workspace_window_arguments,
    },
)
# IPCCommandExecutionResult.swift:204 encodes the kind discriminator.
if first_sort_toggle_result.get("kind") != "applied":
    raise RuntimeError(f"first repo sort toggle did not apply: {first_sort_toggle_result}")
opposite_sort_order = "descending" if initial_sort_order == "ascending" else "ascending"
first_sort_projection = wait_for_repo_sort_projection(
    expected_order=opposite_sort_order,
    after_ns=record_time_ns(initial_sort_projection),
)
second_sort_toggle_result = request(
    "command.execute",
    {
        "commandId":"toggleReposSortDirection",
        "correlationId":str(uuid.uuid4()),
        "arguments":workspace_window_arguments,
    },
)
# IPCCommandExecutionResult.swift:204 encodes the kind discriminator.
if second_sort_toggle_result.get("kind") != "applied":
    raise RuntimeError(f"second repo sort toggle did not apply: {second_sort_toggle_result}")
wait_for_repo_sort_projection(
    expected_order=initial_sort_order,
    after_ns=record_time_ns(first_sort_projection),
)
title_baseline = quiescent_snapshot()
private_title = "cadence-private-title"
private_payload = "printf-private-payload"
ordinary_command = (
    "printf '\\033]0;cadence-private-title\\007'; "
    "i=0; while [ \"$i\" -lt 256 ]; do printf 'printf-private-payload-%03d\\n' \"$i\"; "
    "i=$((i+1)); done; sleep 2\n"
)
title_interval_start_ns = time.time_ns()
request("terminal.send", {"handle":handle,"input":ordinary_command})
request("terminal.wait", {"handle":handle,"condition":"titleChanged","timeoutSeconds":5})
title_interval_end_ns = time.time_ns()
request("terminal.wait", {"handle":handle,"condition":"commandFinished","timeoutSeconds":5})
title_delta = wait_for_delta(title_baseline, lambda value: value["canonical_accepted"] >= 1 and value["tab_affected"] >= 1, "title publication telemetry")
title_after = quiescent_snapshot()
title_delta = delta(title_baseline, title_after)
if title_delta["canonical_accepted"] != 1:
    raise RuntimeError(f"title phase expected one canonical mutation: {title_delta}")
if title_delta["structural_accepted"] != 0:
    raise RuntimeError(f"title phase accepted structural mutation: {title_delta}")
if any(title_delta[key] != 0 for key in ("repo_events", "repo_affected", "repo_resolutions", "repo_capability_snapshots", "repo_projection")):
    raise RuntimeError(f"title phase performed Repo work: {title_delta}")
if title_delta["tab_affected"] != 1:
    raise RuntimeError(f"title phase must affect exactly the owning tab: {title_delta}")
equal_title_offer_count = 20
equal_title_baseline = quiescent_snapshot()
for _ in range(equal_title_offer_count):
    request(
        "terminal.send",
        {"handle":handle,"input":"printf '\\033]0;cadence-private-title\\007'\n"},
    )
    request("terminal.wait", {"handle":handle,"condition":"commandFinished","timeoutSeconds":5})
equal_title_after = quiescent_snapshot()
equal_title_delta = delta(equal_title_baseline, equal_title_after)
equal_title_admitted_count = (
    equal_title_delta["equal_title_suppressed"] + equal_title_delta["scheduled_title_drains"]
)
if equal_title_admitted_count < 10:
    raise RuntimeError(
        "stimulus_invalid: equal-title phase admitted fewer than 10 equal offers: "
        f"offers={equal_title_offer_count} admitted_equal={equal_title_admitted_count} delta={equal_title_delta}"
    )
equal_title_ratio_failures = []
if equal_title_delta["equal_title_suppressed"] * 10 < equal_title_admitted_count * 9:
    equal_title_ratio_failures.append(
        "equal-title phase suppressed less than 90% of admitted equal offers"
    )
if equal_title_delta["scheduled_title_drains"] * 10 > equal_title_admitted_count:
    equal_title_ratio_failures.append(
        "equal-title phase drained more than 10% of admitted equal offers"
    )
if equal_title_ratio_failures:
    raise RuntimeError(
        f"{'; '.join(equal_title_ratio_failures)}: offers={equal_title_offer_count} "
        f"admitted_equal={equal_title_admitted_count} delta={equal_title_delta}"
    )
if equal_title_delta["canonical_accepted"] > equal_title_offer_count:
    raise RuntimeError(
        f"equal-title phase canonical mutations exceeded driver sends: offers={equal_title_offer_count} "
        f"delta={equal_title_delta}"
    )
print(
    "equal-title phase: "
    f"offers={equal_title_offer_count} "
    f"admitted_equal={equal_title_admitted_count} "
    f"scheduled_title_drains={equal_title_delta['scheduled_title_drains']} "
    f"equal_suppressed={equal_title_delta['equal_title_suppressed']} "
    f"apply_outcome_equal={equal_title_delta['title_apply_equal']} "
    f"apply_outcome_changed={equal_title_delta['title_apply_changed']} "
    f"canonical_accepted_delta={equal_title_delta['canonical_accepted']}"
)
immediate_records = [
    record for record in marker_records()
    if record.get("_msg") == "performance.terminal.accumulator_drain"
    and record.get("agentstudio.performance.terminal.accumulator.drain.class") == "immediate"
]
if not any(title_interval_start_ns <= record_time_ns(record) <= title_interval_end_ns for record in immediate_records):
    raise RuntimeError("immediate drain did not occur inside the pending-title interval")
request("terminal.send", {"handle":handle,"input":"printf '\\033]0;Cadence Barrier\\007\\033]7;file://localhost/tmp\\007'\n"})
request("terminal.wait", {"handle":handle,"condition":"commandFinished","timeoutSeconds":5})
pane_structural_baseline = quiescent_snapshot()
before = {item["id"] for item in request("pane.list", {}).get("panes", [])}
request("pane.split", {"handle":handle,"direction":"right","correlationId":None})
after = request("pane.list", {}).get("panes", [])
created = next((item for item in after if item["id"] not in before), None)
if created is None: raise RuntimeError("pane.split did not create a pane")
# IPCTargetSelector.swift:19-21 uses bare UUIDs for canonical selectors.
created_handle = created["id"]
request("pane.snapshot", {"handle":created_handle})
request("pane.close", {"handle":created_handle,"correlationId":None})
if created["id"] in {item["id"] for item in request("pane.list", {}).get("panes", [])}:
    raise RuntimeError("pane.close readback retained the created pane")
pane_structural_delta = wait_for_delta(
    pane_structural_baseline,
    lambda value: value["canonical_accepted"] >= 2 and value["structural_accepted"] >= 2,
    "pane structural telemetry",
)
pane_structural_after = quiescent_snapshot()
pane_structural_delta = delta(pane_structural_baseline, pane_structural_after)
if not 1 <= pane_structural_delta["canonical_accepted"] <= 8:
    raise RuntimeError(f"pane structural canonical work was not bounded: {pane_structural_delta}")
if not 1 <= pane_structural_delta["structural_accepted"] <= 8:
    raise RuntimeError(f"pane structural projection work was not bounded: {pane_structural_delta}")
if not 1 <= pane_structural_delta["membership_accepted"] <= 8:
    raise RuntimeError(f"pane membership work was not bounded: {pane_structural_delta}")
capability_baseline = quiescent_snapshot()
capability_baseline_sort_projection = wait_for_repo_sort_projection(expected_order=initial_sort_order)
capability_result = request(
    "command.execute",
    {
        "commandId":"toggleReposSortDirection",
        "correlationId":str(uuid.uuid4()),
        "arguments":workspace_window_arguments,
    },
)
# IPCCommandExecutionResult.swift:204 encodes the kind discriminator.
if capability_result.get("kind") != "applied":
    raise RuntimeError(f"repo sort toggle did not apply: {capability_result}")
capability_delta = wait_for_delta(capability_baseline, lambda value: value["repo_events"] >= 1, "capability presentation telemetry")
capability_after = quiescent_snapshot()
capability_delta = delta(capability_baseline, capability_after)
if capability_delta["repo_events"] != 1 or capability_delta["repo_affected"] <= 0:
    raise RuntimeError(f"capability phase expected one affected Repo command batch: {capability_delta}")
if not 1 <= capability_delta["repo_resolutions"] <= 64:
    raise RuntimeError(f"capability command resolutions were not bounded: {capability_delta}")
if capability_delta["repo_capability_snapshots"] != 1:
    raise RuntimeError(f"capability phase expected one coherent snapshot: {capability_delta}")
if capability_delta["tab_affected"] != 0:
    raise RuntimeError(f"capability phase affected unrelated tab items: {capability_delta}")
capability_sort_projection = wait_for_repo_sort_projection(
    expected_order=opposite_sort_order,
    after_ns=record_time_ns(capability_baseline_sort_projection),
)
capability_restore_result = request(
    "command.execute",
    {
        "commandId":"toggleReposSortDirection",
        "correlationId":str(uuid.uuid4()),
        "arguments":workspace_window_arguments,
    },
)
# IPCCommandExecutionResult.swift:204 encodes the kind discriminator.
if capability_restore_result.get("kind") != "applied":
    raise RuntimeError(f"repo sort restoration toggle did not apply: {capability_restore_result}")
wait_for_repo_sort_projection(
    expected_order=initial_sort_order,
    after_ns=record_time_ns(capability_sort_projection),
)
rendered_marker_records = json.dumps(marker_records(), sort_keys=True)
if private_title in rendered_marker_records or private_payload in rendered_marker_records:
    raise RuntimeError("sensitive title or payload survived marker-scoped OTLP projection")
reader.close(); sock.close()
PY

marker='agent.proof.marker="'"$TRACE_MARKER"'"'
drain_event='event="performance.terminal.accumulator_drain"'
deadline_query='agentstudio_performance_event_elapsed_ms_max{'"$marker"','"$drain_event"',drain_class="title_deadline"}'
immediate_query='agentstudio_performance_events_total{'"$marker"','"$drain_event"',drain_class="immediate"}'
barrier_query='agentstudio_performance_events_total{'"$marker"','"$drain_event"',drain_class="exact_barrier"}'
equal_outcome_query='agentstudio_performance_events_total{'"$marker"','"$drain_event"',outcome="equal"}'
changed_outcome_query='agentstudio_performance_events_total{'"$marker"','"$drain_event"',outcome="changed"}'
for _ in $(seq 1 "$METRIC_EXPORT_ATTEMPTS"); do
  deadline_ms="$(query_value "$deadline_query")"
  immediate_count="$(query_value "$immediate_query")"
  barrier_count="$(query_value "$barrier_query")"
  equal_outcome_count="$(query_value "$equal_outcome_query")"
  changed_outcome_count="$(query_value "$changed_outcome_query")"
  [ "$deadline_ms" != 0 ] && [ "$immediate_count" != 0 ] && [ "$barrier_count" != 0 ] \
    && [ "$changed_outcome_count" != 0 ] && break
  /bin/sleep 2
done
/usr/bin/python3 - "$deadline_ms" "$immediate_count" "$barrier_count" "$equal_outcome_count" "$changed_outcome_count" <<'PY'
import sys
deadline, immediate, barrier, equal_outcome, changed_outcome = map(float, sys.argv[1:])
if not 0 < deadline <= 1000: raise SystemExit(f"title_deadline outside bound: {deadline}")
if immediate < 1: raise SystemExit("missing immediate drain")
if barrier < 1: raise SystemExit("missing exact_barrier drain")
if changed_outcome < 1: raise SystemExit("missing changed title apply outcome")
print(f"title apply outcomes: equal={equal_outcome:g} changed={changed_outcome:g}")
PY
echo "title and pane performance proof ok: marker=$TRACE_MARKER"
