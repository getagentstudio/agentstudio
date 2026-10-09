#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
JOURNEY_STATE_FILE="${AGENTSTUDIO_BRIDGE_PACKAGED_JOURNEY_STATE_FILE:-$PROJECT_ROOT/tmp/debug-observability/latest-bridge-packaged-product-journey.env}"
LSOF_BIN="${AGENTSTUDIO_LSOF_BIN:-/usr/sbin/lsof}"
GIT_BIN=/usr/bin/git
SHASUM_BIN=/usr/bin/shasum
FIXTURE_REPOSITORY_URL=https://github.com/askluna/fork-for-fixture-agentstudio.git
FIXTURE_BASE_REF=fixture-for-bridge-review-performance-2026-09-02-base
FIXTURE_BASE_SHA=246c9a81c256ded9431620ae9c8cd99f4a27622d
FIXTURE_HEAD_REF=fixture-for-bridge-review-performance-2026-09-02-head
FIXTURE_HEAD_SHA=40441ec0ad71c48bdc9d8611c2308ed788f65216
MINIMUM_REAL_FIXTURE_TRACKED_FILE_COUNT=3886
MINIMUM_REAL_FIXTURE_REVIEW_DIFF_COUNT=925
MINIMUM_REAL_FIXTURE_DIFF_HUNK_COUNT=4321
MINIMUM_REAL_FIXTURE_CHANGED_CONTENT_LINE_COUNT=354002
MINIMUM_REAL_FIXTURE_CHANGED_CONTENT_BYTE_COUNT=14000000

dry_run=false
complete_journey=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run)
      dry_run=true
      shift
      ;;
    --complete-journey)
      complete_journey=true
      shift
      ;;
    *)
      echo "usage: verify-bridge-packaged-product-journey.sh [--dry-run] [--complete-journey]" >&2
      exit 2
      ;;
  esac
done

if [ "$dry_run" = true ]; then
  cat <<'DRY_RUN'
dry-run ok: binds bundle/executable/assets to the current candidate
dry-run ok: interactive verification mode preserves the existing live semantic and visual proof
dry-run ok: complete journey cohort mode validates exactly 3 stopped isolated launches and raw receipts
dry-run ok: complete journey cohort mode reduces four native journeys with exact pane telemetry proof
dry-run ok: uses one persistent authenticated semantic IPC session
dry-run ok: interactive mode requires exactly 257 initial Review diffs before IPC authentication
dry-run ok: complete mode requires the pinned real fixture identity, commits, and workload envelope
dry-run ok: retains the 100-diff floor before IPC authentication
dry-run ok: proves Review early/middle/final traversal
dry-run ok: proves two independent panes and hidden-to-foreground refresh
dry-run ok: reactivates the exact packaged app before every foreground pane phase
dry-run ok: hard-cuts Files and Review Filter candidates with semantic read-back
dry-run ok: proves supported Search admission and length boundaries
dry-run ok: proves the disposable worktree remains read-only
dry-run ok: binds Victoria marker and proof token
dry-run ok: waits for Computer Use UI selection before verification
dry-run ok: requires visible document and live RAF; no frame_not_live skip
dry-run ok: proves exact package origin and core.sqlite symbolic intent
dry-run ok: proves automatic Git-ref invalidation without bridge.diff.refresh
dry-run ok: does not embed desktop automation
dry-run ok: interprets raw one-row comparison geometry
dry-run ok: proves the bundled agentstudio CLI executable runs its own argument parser
DRY_RUN
  exit 0
fi

# The pane environment advertises AGENTSTUDIO_CLI at Contents/Helpers/agentstudio.
# It cannot live in Contents/MacOS because that path collides with the app's own
# executable on case-insensitive volumes. The CLI has no --help verb, so an
# argument-free invocation is the cheapest proof that the real binary loaded and
# ran its own parser instead of failing to execute (126/127) or crashing.
require_bundled_agentstudio_cli() {
  local app_bundle="${1:?missing app bundle}"
  local cli_path="$app_bundle/Contents/Helpers/agentstudio"
  local cli_stderr
  local cli_status=0
  if [ ! -x "$cli_path" ]; then
    echo "Bridge packaged journey bundle is missing an executable agentstudio CLI: $cli_path" >&2
    exit 1
  fi
  cli_stderr="$("$cli_path" 2>&1 >/dev/null)" || cli_status=$?
  if [ "$cli_status" -ne 1 ] || [[ "$cli_stderr" != *'"reason":"invalidParams"'* ]]; then
    echo "Bridge packaged journey bundled agentstudio CLI did not run its argument parser: $cli_path" >&2
    echo "exit status: $cli_status" >&2
    echo "stderr: $cli_stderr" >&2
    exit 1
  fi
}

decode_state_value() {
  /usr/bin/python3 - "$1" <<'PY'
import shlex
import sys

try:
    values = shlex.split(sys.argv[1])
except ValueError:
    values = []
print(values[0] if values else "")
PY
}

fixture_digest_for_current_worktree() {
  local fixture_path="${1:?missing fixture path}"
  local fixture_baseline="${2:?missing fixture baseline}"
  local content_oid
  local index_metadata
  local index_mode
  local index_oid
  local index_record
  local relative_path
  {
    printf 'baseline\0%s\0' "$fixture_baseline"
    while IFS= read -r -d '' index_record; do
      index_metadata="${index_record%%$'\t'*}"
      relative_path="${index_record#*$'\t'}"
      read -r index_mode index_oid _ <<<"$index_metadata"
      if [ "$index_mode" = 160000 ]; then
        content_oid="$index_oid"
      else
        content_oid="$($GIT_BIN -C "$fixture_path" hash-object -- "$relative_path")"
      fi
      printf 'path\0%s\0blob\0%s\0' "$relative_path" "$content_oid"
    done < <("$GIT_BIN" -C "$fixture_path" ls-files -s -z)
  } | "$SHASUM_BIN" -a 256 | awk '{ print $1 }'
}

measure_fixture_counts() {
  local fixture_path="${1:?missing fixture path}"
  local fixture_baseline="${2:?missing fixture baseline}"
  local fixture_head="${3:?missing fixture head}"
  /usr/bin/python3 - "$fixture_path" "$fixture_baseline" "$fixture_head" "$GIT_BIN" <<'PY'
import os
import subprocess
import sys

fixture_root, base_sha, head_sha, git_bin = sys.argv[1:]


def git_bytes(*arguments):
    return subprocess.check_output([git_bin, "-C", fixture_root, *arguments])


tracked_paths = [path for path in git_bytes("ls-files", "-z").split(b"\0") if path]
changed_paths = [
    os.fsdecode(path)
    for path in git_bytes(
        "diff", "--no-renames", "--name-only", "-z", base_sha, head_sha, "--"
    ).split(b"\0")
    if path
]
changed_content_line_count = 0
changed_content_byte_count = 0
for relative_path in changed_paths:
    absolute_path = os.path.join(fixture_root, relative_path)
    if not os.path.isfile(absolute_path):
        continue
    with open(absolute_path, "rb") as source_file:
        content = source_file.read()
    changed_content_line_count += content.count(b"\n")
    changed_content_byte_count += len(content)

diff_process = subprocess.Popen(
    [git_bin, "-C", fixture_root, "diff", "--no-color", "--unified=0", base_sha, head_sha, "--"],
    stdout=subprocess.PIPE,
)
if diff_process.stdout is None:
    raise SystemExit("pinned fixture diff stream is unavailable")
diff_hunk_count = sum(1 for line in diff_process.stdout if line.startswith(b"@@ "))
if diff_process.wait() != 0:
    raise SystemExit("pinned fixture diff failed while measuring hunks")

print(
    "\t".join(
        str(value)
        for value in (
            len(tracked_paths),
            diff_hunk_count,
            changed_content_line_count,
            changed_content_byte_count,
        )
    )
)
PY
}

journey_status=""
journey_root=""
journey_data_root=""
observability_state_file=""
fixture_root=""
expected_file_count=""
expected_review_diff_count=""
expected_fixture_digest=""
baseline_commit=""
early_path=""
middle_path=""
final_path=""
tracked_path=""
reviewed_branch_name=""
comparison_target_name=""
journey_mode=""
complete_journey_attempt_count=""
source_head=""
fixture_identity=""
fixture_base_sha=""
fixture_head_sha=""
tracked_file_count=""
diff_hunk_count=""
changed_content_line_count=""
changed_content_byte_count=""

if [ ! -f "$JOURNEY_STATE_FILE" ]; then
  echo "Bridge packaged journey state is missing: $JOURNEY_STATE_FILE" >&2
  exit 1
fi

while IFS='=' read -r key raw_value; do
  value="$(decode_state_value "$raw_value")"
  case "$key" in
    AGENTSTUDIO_BRIDGE_JOURNEY_STATUS) journey_status="$value" ;;
    AGENTSTUDIO_BRIDGE_JOURNEY_MODE) journey_mode="$value" ;;
    AGENTSTUDIO_BRIDGE_JOURNEY_COMPLETE_ATTEMPT_COUNT) complete_journey_attempt_count="$value" ;;
    AGENTSTUDIO_BRIDGE_JOURNEY_SOURCE_HEAD) source_head="$value" ;;
    JOURNEY_ROOT) journey_root="$value" ;;
    AGENTSTUDIO_BRIDGE_JOURNEY_DATA_ROOT) journey_data_root="$value" ;;
    AGENTSTUDIO_BRIDGE_JOURNEY_OBSERVABILITY_STATE_FILE) observability_state_file="$value" ;;
    AGENTSTUDIO_IPC_DEBUG_TOKEN_ESCROW) ipc_debug_escrow_path="$value" ;;
    AGENTSTUDIO_BRIDGE_JOURNEY_FIXTURE_ROOT) fixture_root="$value" ;;
    AGENTSTUDIO_BRIDGE_JOURNEY_FIXTURE_IDENTITY) fixture_identity="$value" ;;
    AGENTSTUDIO_BRIDGE_JOURNEY_FIXTURE_BASE_SHA) fixture_base_sha="$value" ;;
    AGENTSTUDIO_BRIDGE_JOURNEY_FIXTURE_HEAD_SHA) fixture_head_sha="$value" ;;
    AGENTSTUDIO_BRIDGE_JOURNEY_TRACKED_FILE_COUNT) tracked_file_count="$value" ;;
    AGENTSTUDIO_BRIDGE_JOURNEY_DIFF_HUNK_COUNT) diff_hunk_count="$value" ;;
    AGENTSTUDIO_BRIDGE_JOURNEY_CHANGED_CONTENT_LINE_COUNT) changed_content_line_count="$value" ;;
    AGENTSTUDIO_BRIDGE_JOURNEY_CHANGED_CONTENT_BYTE_COUNT) changed_content_byte_count="$value" ;;
    AGENTSTUDIO_BRIDGE_JOURNEY_EXPECTED_FILE_COUNT) expected_file_count="$value" ;;
    AGENTSTUDIO_BRIDGE_JOURNEY_EXPECTED_REVIEW_DIFF_COUNT) expected_review_diff_count="$value" ;;
    AGENTSTUDIO_BRIDGE_JOURNEY_FIXTURE_DIGEST) expected_fixture_digest="$value" ;;
    BASELINE_COMMIT) baseline_commit="$value" ;;
    AGENTSTUDIO_BRIDGE_JOURNEY_EARLY_PATH) early_path="$value" ;;
    AGENTSTUDIO_BRIDGE_JOURNEY_MIDDLE_PATH) middle_path="$value" ;;
    AGENTSTUDIO_BRIDGE_JOURNEY_FINAL_PATH) final_path="$value" ;;
    AGENTSTUDIO_BRIDGE_JOURNEY_TRACKED_PATH) tracked_path="$value" ;;
    AGENTSTUDIO_BRIDGE_JOURNEY_REVIEWED_BRANCH_NAME) reviewed_branch_name="$value" ;;
    AGENTSTUDIO_BRIDGE_JOURNEY_TARGET_NAME) comparison_target_name="$value" ;;
  esac
done <"$JOURNEY_STATE_FILE"

if [ "$complete_journey" = true ]; then
  if [ "$journey_mode" != "complete-journey" ] || [ "$journey_status" != "cohort_ready" ]; then
    echo "Bridge packaged complete journey cohort is not ready: ${journey_status:-<missing>}" >&2
    exit 1
  fi
else
  if [ "$journey_status" != "running" ]; then
    echo "Bridge packaged journey is not running: ${journey_status:-<missing>}" >&2
    exit 1
  fi
  if [ ! -f "$observability_state_file" ]; then
    echo "Bridge packaged journey observability state is missing: ${observability_state_file:-<missing>}" >&2
    exit 1
  fi
fi
if [ ! -d "$fixture_root/.git" ]; then
  echo "Bridge packaged journey fixture is not a Git worktree: ${fixture_root:-<missing>}" >&2
  exit 1
fi
case "$expected_file_count" in
  ''|*[!0-9]*)
    echo "Bridge packaged journey expected file count is invalid: ${expected_file_count:-<missing>}" >&2
    exit 1
    ;;
esac
case "$expected_review_diff_count" in
  ''|*[!0-9]*)
    echo "Bridge packaged journey expected Review diff count is invalid: $expected_review_diff_count" >&2
    exit 1
    ;;
esac
if [ "$complete_journey" = true ]; then
  if [ "$fixture_identity" != "pinned-real-worktree" ]; then
    echo "Bridge packaged complete journey requires the pinned-real-worktree fixture" >&2
    exit 1
  fi
  if [ "$fixture_base_sha" != "$FIXTURE_BASE_SHA" ] \
    || [ "$fixture_head_sha" != "$FIXTURE_HEAD_SHA" ]; then
    echo "Bridge packaged complete journey fixture commit identity mismatch" >&2
    exit 1
  fi
  for profile_count in \
    "$tracked_file_count" \
    "$diff_hunk_count" \
    "$changed_content_line_count" \
    "$changed_content_byte_count"; do
    case "$profile_count" in
      ''|*[!0-9]*)
        echo "Bridge packaged complete journey fixture profile is invalid" >&2
        exit 1
        ;;
    esac
  done
  if [ "$expected_file_count" -ne "$tracked_file_count" ] \
    || [ "$tracked_file_count" -lt "$MINIMUM_REAL_FIXTURE_TRACKED_FILE_COUNT" ] \
    || [ "$expected_review_diff_count" -lt "$MINIMUM_REAL_FIXTURE_REVIEW_DIFF_COUNT" ] \
    || [ "$diff_hunk_count" -lt "$MINIMUM_REAL_FIXTURE_DIFF_HUNK_COUNT" ] \
    || [ "$changed_content_line_count" -lt "$MINIMUM_REAL_FIXTURE_CHANGED_CONTENT_LINE_COUNT" ] \
    || [ "$changed_content_byte_count" -lt "$MINIMUM_REAL_FIXTURE_CHANGED_CONTENT_BYTE_COUNT" ]; then
    echo "Bridge packaged complete journey fixture profile is below the required real-repository envelope" >&2
    exit 1
  fi
else
  if [ "$expected_file_count" -ne 257 ]; then
    echo "Bridge packaged journey expected file count must be exactly 257: $expected_file_count" >&2
    exit 1
  fi
  if [ "$expected_review_diff_count" -ne "$expected_file_count" ]; then
    echo "Bridge packaged journey expected Review diff count must equal expected file count: expected $expected_file_count, observed $expected_review_diff_count" >&2
    exit 1
  fi
  if [ "$expected_review_diff_count" -lt 100 ]; then
    echo "Bridge packaged journey rejects fewer than 100 initial Review diffs: $expected_review_diff_count" >&2
    exit 1
  fi
fi
case "$expected_fixture_digest" in
  ''|*[!0-9a-f]*)
    echo "Bridge packaged journey fixture digest is invalid" >&2
    exit 1
    ;;
esac
if [ "${#expected_fixture_digest}" -ne 64 ]; then
  echo "Bridge packaged journey fixture digest is invalid" >&2
  exit 1
fi
if [ -z "$baseline_commit" ] \
  || ! "$GIT_BIN" -C "$fixture_root" cat-file -e "$baseline_commit^{commit}" 2>/dev/null; then
  echo "Bridge packaged journey baseline commit is invalid" >&2
  exit 1
fi
if [ "$complete_journey" = true ]; then
  if [ "$baseline_commit" != "$FIXTURE_BASE_SHA" ] \
    || [ "$("$GIT_BIN" -C "$fixture_root" rev-parse refs/fixture-source/base)" != "$FIXTURE_BASE_SHA" ] \
    || [ "$("$GIT_BIN" -C "$fixture_root" rev-parse refs/fixture-source/head)" != "$FIXTURE_HEAD_SHA" ] \
    || [ "$("$GIT_BIN" -C "$fixture_root" rev-parse "refs/heads/$reviewed_branch_name")" != "$FIXTURE_HEAD_SHA" ] \
    || [ "$("$GIT_BIN" -C "$fixture_root" rev-parse "refs/heads/$comparison_target_name")" != "$FIXTURE_BASE_SHA" ]; then
    echo "Bridge packaged complete journey disposable refs do not match pinned fixture authority" >&2
    exit 1
  fi
  if [ "$("$GIT_BIN" -C "$fixture_root" remote get-url origin)" != "$FIXTURE_REPOSITORY_URL" ]; then
    echo "Bridge packaged complete journey fixture remote identity mismatch" >&2
    exit 1
  fi
  if [ -n "$("$GIT_BIN" -C "$fixture_root" status --porcelain --untracked-files=all)" ]; then
    echo "Bridge packaged complete journey fixture is not clean before verification" >&2
    exit 1
  fi
  if "$GIT_BIN" -C "$fixture_root" rev-list --objects --missing=print \
    "$FIXTURE_BASE_SHA" "$FIXTURE_HEAD_SHA" | awk '/^\?/ { missing = 1 } END { exit missing ? 0 : 1 }'; then
    echo "Bridge packaged complete journey fixture is missing reachable Git objects" >&2
    exit 1
  fi
  measured_profile="$(measure_fixture_counts "$fixture_root" "$FIXTURE_BASE_SHA" "$FIXTURE_HEAD_SHA")"
  IFS=$'\t' read -r measured_tracked_file_count measured_diff_hunk_count \
    measured_changed_content_line_count measured_changed_content_byte_count \
    <<<"$measured_profile"
  if [ "$measured_tracked_file_count" -ne "$tracked_file_count" ] \
    || [ "$measured_diff_hunk_count" -ne "$diff_hunk_count" ] \
    || [ "$measured_changed_content_line_count" -ne "$changed_content_line_count" ] \
    || [ "$measured_changed_content_byte_count" -ne "$changed_content_byte_count" ]; then
    echo "Bridge packaged complete journey fixture profile receipt does not match materialized content" >&2
    exit 1
  fi
fi
actual_review_diff_count="$(
  "$GIT_BIN" -C "$fixture_root" diff --no-renames --name-only "$baseline_commit" -- \
    | awk 'NF { count += 1 } END { print count + 0 }'
)"
if [ "$actual_review_diff_count" -ne "$expected_review_diff_count" ]; then
  echo "Bridge packaged journey initial Review diff count mismatch: expected $expected_review_diff_count, observed $actual_review_diff_count" >&2
  exit 1
fi
actual_fixture_digest="$(fixture_digest_for_current_worktree "$fixture_root" "$baseline_commit")"
if [ "$actual_fixture_digest" != "$expected_fixture_digest" ]; then
  echo "Bridge packaged journey fixture digest mismatch" >&2
  exit 1
fi
for required_path in "$early_path" "$middle_path" "$final_path" "$tracked_path"; do
  if [ -z "$required_path" ] || [ ! -f "$fixture_root/$required_path" ]; then
    echo "Bridge packaged journey sentinel is missing: ${required_path:-<missing>}" >&2
    exit 1
  fi
done

if [ "$complete_journey" = true ]; then
  if [ "$journey_data_root" != "$journey_root/app-data" ]; then
    echo "Bridge packaged complete journey data root is not isolated inside its journey" >&2
    exit 1
  fi
  case "$complete_journey_attempt_count" in
    ''|*[!0-9]*)
      echo "Bridge packaged complete journey attempt count is invalid" >&2
      exit 1
      ;;
  esac
  if [ "$complete_journey_attempt_count" -le 0 ]; then
    echo "Bridge packaged complete journey attempt count must be positive" >&2
    exit 1
  fi
  case "$source_head" in
    ''|*[!0-9a-f]*)
      echo "Bridge packaged complete journey source HEAD is invalid" >&2
      exit 1
      ;;
  esac
  if [ "${#source_head}" -ne 40 ]; then
    echo "Bridge packaged complete journey source HEAD is invalid" >&2
    exit 1
  fi
  if [ "$source_head" != "$($GIT_BIN -C "$PROJECT_ROOT" rev-parse HEAD)" ]; then
    echo "Bridge packaged complete journey source HEAD no longer matches the current candidate" >&2
    exit 1
  fi

  for launch_number in 1 2 3; do
    launch_id="native-launch-$launch_number"
    receipt_path="$journey_root/$launch_id.json"
    observability_state_path="$journey_root/$launch_id-observability.env"
    if [ ! -f "$receipt_path" ] || [ ! -f "$observability_state_path" ]; then
      echo "Bridge packaged complete journey is missing $launch_id receipt or state" >&2
      exit 1
    fi
    launch_pid="$(decode_state_value "$(sed -n 's/^AGENTSTUDIO_OBSERVABILITY_PID=//p' "$observability_state_path" | tail -1)")"
    case "$launch_pid" in
      ''|*[!0-9]*)
        echo "Bridge packaged complete journey $launch_id PID is invalid" >&2
        exit 1
        ;;
    esac
    if kill -0 "$launch_pid" >/dev/null 2>&1; then
      echo "Bridge packaged complete journey $launch_id exact PID is still live" >&2
      exit 1
    fi
  done

  candidate_state_path="$journey_root/native-launch-1-observability.env"
  candidate_app="$(decode_state_value "$(sed -n 's/^AGENTSTUDIO_OBSERVABILITY_APP=//p' "$candidate_state_path" | tail -1)")"
  candidate_executable="$(decode_state_value "$(sed -n 's/^AGENTSTUDIO_OBSERVABILITY_EXECUTABLE=//p' "$candidate_state_path" | tail -1)")"
  if [ -z "$candidate_app" ] || [ -z "$candidate_executable" ] || [ ! -x "$candidate_executable" ]; then
    echo "Bridge packaged complete journey candidate identity is incomplete" >&2
    exit 1
  fi
  /usr/bin/codesign --verify --deep --strict "$candidate_app"
  require_bundled_agentstudio_cli "$candidate_app"
  packaged_bridge_web="$candidate_app/Contents/Resources/AgentStudio_AgentStudio.bundle/BridgeWeb/app"
  source_bridge_web="$PROJECT_ROOT/Sources/AgentStudio/Resources/BridgeWeb/app"
  if ! cmp -s "$source_bridge_web/agentstudio-app-assets.json" "$packaged_bridge_web/agentstudio-app-assets.json"; then
    echo "Bridge packaged complete journey asset manifest does not match the current source build" >&2
    exit 1
  fi
  audit_file="$PROJECT_ROOT/tmp/bridge-web-assets/latest-app-asset-audit.json"
  if [ ! -f "$audit_file" ]; then
    echo "Bridge packaged complete journey asset audit is missing" >&2
    exit 1
  fi
  audit_commit="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["git"]["commit"])' "$audit_file")"
  if [ "$audit_commit" != "$source_head" ]; then
    echo "Bridge packaged complete journey asset audit does not match its source HEAD" >&2
    exit 1
  fi

  reducer_input="$journey_root/native-complete-journey-input.json"
  reducer_output="$PROJECT_ROOT/tmp/bridge-complete-journey-native/$(basename "$journey_root")/bridge-complete-journey-native.json"
  /usr/bin/python3 - "$journey_root" "$journey_data_root" "$source_head" \
    "$expected_fixture_digest" "$complete_journey_attempt_count" "$reducer_input" <<'PY'
import json
import os
import plistlib
import shlex
import sys

journey_root, data_root, source_head, fixture_hash, raw_attempt_count, output_path = sys.argv[1:]
attempt_count = int(raw_attempt_count)
launches = []
candidate_identity = None


def read_state(path):
    values = {}
    with open(path, "r", encoding="utf-8") as state_file:
        for line in state_file:
            key, separator, raw_value = line.rstrip("\n").partition("=")
            if not separator:
                continue
            decoded = shlex.split(raw_value)
            values[key] = decoded[0] if decoded else ""
    return values


for launch_number in (1, 2, 3):
    launch_id = f"native-launch-{launch_number}"
    receipt_path = os.path.join(journey_root, f"{launch_id}.json")
    state_path = os.path.join(journey_root, f"{launch_id}-observability.env")
    state = read_state(state_path)
    if state.get("AGENTSTUDIO_OBSERVABILITY_STATUS") != "running":
        raise SystemExit(f"{launch_id} did not record a running candidate")
    if state.get("AGENTSTUDIO_OBSERVABILITY_LAUNCH_METHOD") != "launchservices":
        raise SystemExit(f"{launch_id} was not launched through LaunchServices")
    expected_data_root = os.path.join(data_root, launch_id)
    if os.path.realpath(state.get("AGENTSTUDIO_OBSERVABILITY_DATA_DIR", "")) != os.path.realpath(expected_data_root):
        raise SystemExit(f"{launch_id} did not use its isolated app-data root")
    marker = state.get("AGENTSTUDIO_OBSERVABILITY_MARKER", "")
    proof_token = state.get("AGENTSTUDIO_OBSERVABILITY_PROOF_TOKEN", "")
    if not marker or not proof_token:
        raise SystemExit(f"{launch_id} is missing marker/proof binding")
    app_path = state.get("AGENTSTUDIO_OBSERVABILITY_APP", "")
    executable_path = state.get("AGENTSTUDIO_OBSERVABILITY_EXECUTABLE", "")
    expected_executable = os.path.join(app_path, "Contents", "MacOS", "AgentStudio")
    if not app_path or os.path.realpath(executable_path) != os.path.realpath(expected_executable):
        raise SystemExit(f"{launch_id} candidate app/executable identity is invalid")
    identity = (os.path.realpath(app_path), os.path.realpath(executable_path))
    if candidate_identity is None:
        candidate_identity = identity
    elif candidate_identity != identity:
        raise SystemExit("native launches did not use one exact packaged candidate")
    plist_path = os.path.join(app_path, "Contents", "Info.plist")
    with open(plist_path, "rb") as plist_file:
        service_version = plistlib.load(plist_file).get("CFBundleShortVersionString")
    if not isinstance(service_version, str) or not service_version:
        raise SystemExit(f"{launch_id} candidate service version is missing")
    with open(receipt_path, "r", encoding="utf-8") as receipt_file:
        receipt = json.load(receipt_file)
    if receipt.get("launchId") != launch_id:
        raise SystemExit(f"{launch_id} raw receipt identity mismatch")
    attempts = receipt.get("attemptsByJourney")
    expected_journeys = {"firstFile", "firstReview", "fileToReview", "reviewToFile"}
    if not isinstance(attempts, dict) or set(attempts) != expected_journeys:
        raise SystemExit(f"{launch_id} raw receipt has an invalid journey catalog")
    if any(not isinstance(attempts[journey], list) or len(attempts[journey]) != attempt_count for journey in expected_journeys):
        raise SystemExit(f"{launch_id} raw receipt attempt count mismatch")
    launches.append({
        "launchId": launch_id,
        "receipt": receipt,
        "telemetryMarker": marker,
        "telemetryServiceVersion": service_version,
    })

with open(output_path, "w", encoding="utf-8") as output_file:
    json.dump(
        {"launches": launches, "sourceHead": source_head, "worktreeHash": fixture_hash},
        output_file,
        separators=(",", ":"),
    )
    output_file.write("\n")
os.chmod(output_path, 0o600)
PY

  reducer_status=0
  node --experimental-strip-types \
    "$PROJECT_ROOT/BridgeWeb/scripts/reduce-bridge-complete-journey-native.ts" \
    --input "$reducer_input" \
    --output "$reducer_output" || reducer_status=$?
  /bin/rm -f "$reducer_input"
  if [ "$reducer_status" -ne 0 ]; then
    echo "Bridge packaged complete journey evidence missed a required cohort gate" >&2
    echo "artifact preserved at: $reducer_output" >&2
    exit "$reducer_status"
  fi

  diagnostic_only="$(
    /usr/bin/python3 -c \
      'import json,sys; print("true" if json.load(open(sys.argv[1], encoding="utf-8"))["diagnosticOnly"] else "false")' \
      "$reducer_output"
  )"
  if [ "$diagnostic_only" = true ]; then
    echo "Bridge packaged complete journey DIAGNOSTIC ONLY - no SLO claim"
  else
    echo "Bridge packaged complete journey cohort PASS"
  fi
  echo "artifact=$reducer_output"
  echo "fixture=$fixture_root"
  exit 0
fi

state_status=""
state_pid=""
state_app=""
state_executable=""
state_data_dir=""
state_launch_method=""
state_marker=""
state_proof_token=""
while IFS='=' read -r key raw_value; do
  value="$(decode_state_value "$raw_value")"
  case "$key" in
    AGENTSTUDIO_OBSERVABILITY_STATUS) state_status="$value" ;;
    AGENTSTUDIO_OBSERVABILITY_PID) state_pid="$value" ;;
    AGENTSTUDIO_OBSERVABILITY_APP) state_app="$value" ;;
    AGENTSTUDIO_OBSERVABILITY_EXECUTABLE) state_executable="$value" ;;
    AGENTSTUDIO_OBSERVABILITY_DATA_DIR) state_data_dir="$value" ;;
    AGENTSTUDIO_OBSERVABILITY_LAUNCH_METHOD) state_launch_method="$value" ;;
    AGENTSTUDIO_OBSERVABILITY_MARKER) state_marker="$value" ;;
    AGENTSTUDIO_OBSERVABILITY_PROOF_TOKEN) state_proof_token="$value" ;;
  esac
done <"$observability_state_file"

if [ "$journey_data_root" != "$journey_root/app-data" ]; then
  echo "Bridge packaged journey application data root is not isolated inside its journey" >&2
  exit 1
fi
if [ "$state_data_dir" != "$journey_data_root" ]; then
  echo "Bridge packaged journey candidate did not launch with its isolated application data root" >&2
  exit 1
fi

if [ "$state_status" != "running" ] || [ "$state_launch_method" != "launchservices" ]; then
  echo "Bridge packaged journey requires a running strict LaunchServices candidate" >&2
  exit 1
fi
case "$state_pid" in
  ''|*[!0-9]*)
    echo "Bridge packaged journey state is missing a numeric PID" >&2
    exit 1
    ;;
esac
if ! kill -0 "$state_pid" >/dev/null 2>&1; then
  echo "Bridge packaged journey PID is not running: $state_pid" >&2
  exit 1
fi
if [ -z "$state_app" ] || [ -z "$state_executable" ] || [ ! -x "$state_executable" ]; then
  echo "Bridge packaged journey app/executable identity is incomplete" >&2
  exit 1
fi
actual_executable="$($LSOF_BIN -a -p "$state_pid" -d txt -Fn 2>/dev/null | awk '/^n/ && !found { print substr($0, 2); found = 1 }')"
expected_executable="$(/usr/bin/python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$state_executable")"
actual_executable="$(/usr/bin/python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$actual_executable")"
if [ "$actual_executable" != "$expected_executable" ]; then
  echo "Bridge packaged journey executable does not match the live PID" >&2
  exit 1
fi
case "$expected_executable" in
  "$state_app"/Contents/MacOS/AgentStudio) ;;
  *)
    echo "Bridge packaged journey executable is not inside the recorded app bundle" >&2
    exit 1
    ;;
esac

/usr/bin/codesign --verify --deep --strict "$state_app"
require_bundled_agentstudio_cli "$state_app"
packaged_bridge_web="$state_app/Contents/Resources/AgentStudio_AgentStudio.bundle/BridgeWeb/app"
source_bridge_web="$PROJECT_ROOT/Sources/AgentStudio/Resources/BridgeWeb/app"
for required_asset in \
  index.html \
  agentstudio-app-assets.json \
  assets/bridge-app.js \
  assets/bridge-comm-worker.js \
  assets/bridge-telemetry-worker.js \
  assets/bridge-markdown-render-worker.js \
  workers/pierre-diffs-worker-portable.js; do
  if [ ! -f "$packaged_bridge_web/$required_asset" ]; then
    echo "Bridge packaged journey bundle is missing asset: $required_asset" >&2
    exit 1
  fi
done
if ! cmp -s "$source_bridge_web/agentstudio-app-assets.json" "$packaged_bridge_web/agentstudio-app-assets.json"; then
  echo "Bridge packaged journey asset manifest does not match the current source build" >&2
  exit 1
fi
audit_file="$PROJECT_ROOT/tmp/bridge-web-assets/latest-app-asset-audit.json"
if [ ! -f "$audit_file" ]; then
  echo "Bridge packaged journey asset audit is missing" >&2
  exit 1
fi
audit_commit="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["git"]["commit"])' "$audit_file")"
candidate_commit="$(git -C "$PROJECT_ROOT" rev-parse HEAD)"
if [ "$audit_commit" != "$candidate_commit" ]; then
  echo "Bridge packaged journey asset audit commit is stale" >&2
  exit 1
fi

AGENTSTUDIO_OBSERVABILITY_STATE_FILE="$observability_state_file" \
  AGENTSTUDIO_REQUIRE_LAUNCHSERVICES=1 \
  /bin/bash "$PROJECT_ROOT/scripts/verify-debug-observability.sh"
/usr/bin/open -a "$state_app"
AGENTSTUDIO_OBSERVABILITY_STATE_FILE="$observability_state_file" \
  /bin/bash "$PROJECT_ROOT/scripts/verify-bridge-product-paint-correlation.sh"

ipc_metadata="$state_data_dir/ipc/runtime.json"
case "${ipc_debug_escrow_path:-}" in
  /*) ;;
  *)
    echo "Bridge packaged journey receipt requires an absolute AGENTSTUDIO_IPC_DEBUG_TOKEN_ESCROW path" >&2
    exit 1
    ;;
esac
if [ ! -f "$ipc_metadata" ] || [ ! -s "$ipc_debug_escrow_path" ]; then
  echo "Bridge packaged journey requires authenticated IPC escrow: AGENTSTUDIO_IPC_DEBUG_TOKEN_ESCROW=$ipc_debug_escrow_path" >&2
  exit 1
fi

AGENTSTUDIO_BRIDGE_JOURNEY_MARKER="$state_marker" \
AGENTSTUDIO_BRIDGE_JOURNEY_PROOF_TOKEN="$state_proof_token" \
AGENTSTUDIO_BRIDGE_JOURNEY_APP="$state_app" \
/usr/bin/python3 - \
  "$ipc_metadata" \
  "$ipc_debug_escrow_path" \
  "$fixture_root" \
  "$expected_file_count" \
  "$expected_review_diff_count" \
  "$early_path" \
  "$middle_path" \
  "$final_path" \
  "$tracked_path" \
  "$state_data_dir" \
  "$comparison_target_name" \
  "$reviewed_branch_name" \
  "$baseline_commit" \
  "$GIT_BIN" <<'PY'
import hashlib
import json
import os
import sqlite3
import socket
import subprocess
import sys
import time

metadata_path, escrow_path, fixture_root = sys.argv[1:4]
expected_file_count = int(sys.argv[4])
expected_review_diff_count = int(sys.argv[5])
sentinel_paths = sys.argv[6:9]
tracked_path = sys.argv[9]
data_root = sys.argv[10]
comparison_target_name = sys.argv[11]
reviewed_branch_name = sys.argv[12]
baseline_commit = sys.argv[13]
git_bin = sys.argv[14]
candidate_app = os.environ.get("AGENTSTUDIO_BRIDGE_JOURNEY_APP", "")
response_timeout = float(os.environ.get("AGENTSTUDIO_BRIDGE_JOURNEY_IPC_TIMEOUT_SECONDS", "20"))


def fail(message):
    print(message, file=sys.stderr)
    raise SystemExit(1)


with open(metadata_path, "r", encoding="utf-8") as file:
    metadata = json.load(file)
socket_path = metadata.get("socketPath")
if not isinstance(socket_path, str) or not socket_path:
    fail("Bridge packaged journey IPC metadata has no socketPath")
with open(escrow_path, "r", encoding="utf-8") as file:
    escrow = json.load(file)
token = escrow.get("token")
if not isinstance(token, str) or not token:
    fail("Bridge packaged journey AGENTSTUDIO_IPC_DEBUG_TOKEN_ESCROW has no token")
if (escrow.get("socketPath") != socket_path or not escrow.get("runtimeId")
        or escrow.get("runtimeId") != metadata.get("runtimeId")):
    fail("Bridge packaged journey AGENTSTUDIO_IPC_DEBUG_TOKEN_ESCROW does not match IPC metadata")


class Session:
    def __init__(self, path):
        self._next_id = 1
        self._socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._socket.settimeout(response_timeout)
        self._socket.connect(path)
        self._reader = self._socket.makefile("rb")

    def close(self):
        self._reader.close()
        self._socket.close()

    def _request_response(self, method, params):
        request_id = self._next_id
        self._next_id += 1
        payload = {"jsonrpc": "2.0", "id": request_id, "method": method, "params": params}
        self._socket.sendall((json.dumps(payload, separators=(",", ":")) + "\n").encode())
        while True:
            line = self._reader.readline()
            if not line:
                fail(f"IPC closed before response for {method}")
            response = json.loads(line)
            if response.get("id") != request_id:
                continue
            return response

    def request(self, method, params):
        response = self._request_response(method, params)
        if response.get("error") is not None:
            fail(f"{method} failed: {response['error']}")
        return response.get("result", {})

    def request_error(self, method, params):
        response = self._request_response(method, params)
        error = response.get("error")
        if error is None:
            fail(f"{method} unexpectedly succeeded when an error was required")
        return error


def wait_for(label, read, accept, attempts=120):
    last = None
    for _ in range(attempts):
        last = read()
        if accept(last):
            return last
        time.sleep(0.1)
    fail(f"{label} did not become ready: {last}")


def require_control(result, method, item_id=None, path=None):
    if result.get("method") != method or result.get("status") != "accepted":
        fail(f"{method} was not accepted: {result}")
    if item_id is not None and result.get("itemId") != item_id:
        fail(f"{method} selected the wrong item: {result}")
    if path is not None and result.get("path") != path:
        fail(f"{method} revealed the wrong path: {result}")


def require_filter_control(result, expected_surface):
    require_control(result, "bridge.fileTree.setFilter")
    if result.get("filterSurface") != expected_surface:
        fail(f"Filter receipt named the wrong surface: {result}")
    if result.get("categoryFilter") != "all":
        fail(f"Filter receipt did not read back the All category: {result}")
    if expected_surface == "review" and (
        result.get("gitStatusFilter") != "all"
        or result.get("showBinary") is not True
        or result.get("showLarge") is not True
    ):
        fail(f"Review Filter receipt did not read back the complete candidate: {result}")


def canonical(value):
    return os.path.realpath(value)


def contribution_origin(package):
    origin = package.get("comparisonOrigin")
    if not isinstance(origin, dict) or origin.get("kind") != "contribution":
        return None
    return origin


def has_exact_origin(package, target_oid, reviewed_oid, base_oid):
    origin = contribution_origin(package)
    if origin is None:
        return False
    symbolic_target = origin.get("symbolicTarget", {})
    return (
        origin.get("baseRole") == "commonCommit"
        and origin.get("comparedRole") == "capturedWorkingTree"
        and symbolic_target
        == {"basis": "commonCommit", "kind": "branch", "name": comparison_target_name}
        and origin.get("resolvedTargetOID") == target_oid
        and origin.get("reviewedHeadOID") == reviewed_oid
        and origin.get("baseOID") == base_oid
    )


def persisted_comparison_target(review_pane_id):
    core_database_path = os.path.join(data_root, "core.sqlite")
    if not os.path.isfile(core_database_path):
        return None
    try:
        connection = sqlite3.connect(f"file:{core_database_path}?mode=ro", uri=True)
        try:
            row = connection.execute(
                "SELECT payload_json FROM pane_content_payload WHERE pane_id = ?",
                (review_pane_id,),
            ).fetchone()
        finally:
            connection.close()
    except sqlite3.Error:
        return None
    if row is None:
        return None
    payload = json.loads(row[0])
    return payload["state"]["source"]["workspace"]["comparisonTarget"]


def git_output(*arguments, input_text=None):
    completed = subprocess.run(
        [git_bin, "-C", fixture_root, *arguments],
        check=False,
        capture_output=True,
        input=input_text,
        text=True,
    )
    if completed.returncode != 0:
        fail(f"Git {' '.join(arguments)} failed: {completed.stderr}")
    return completed.stdout.strip()


def move_comparison_history():
    reviewed_before = git_output("rev-parse", f"refs/heads/{reviewed_branch_name}")
    target_before = git_output("rev-parse", f"refs/heads/{comparison_target_name}")
    tree_oid = git_output("rev-parse", f"{reviewed_before}^{{tree}}")
    reviewed_after = git_output(
        "commit-tree", tree_oid, "-p", reviewed_before, input_text="move reviewed HEAD\n"
    )
    subprocess.run([git_bin, "-C", fixture_root, "update-ref", f"refs/heads/{reviewed_branch_name}", reviewed_after, reviewed_before], check=True)
    target_after = git_output(
        "commit-tree", tree_oid, "-p", reviewed_after, input_text="move comparison target\n"
    )
    subprocess.run([git_bin, "-C", fixture_root, "update-ref", f"refs/heads/{comparison_target_name}", target_after, target_before], check=True)
    return target_before, reviewed_before, target_after, reviewed_after


def require_one_row_geometry(render_state):
    summary = render_state.get("summary", {})
    topbar = summary.get("contentTopbarFrame")
    controls = summary.get("contentTopbarControlsFrame")
    trigger = summary.get("comparisonTriggerFrame")
    if not all(isinstance(frame, dict) for frame in (topbar, controls, trigger)):
        fail(f"Review comparison geometry is missing: {summary}")
    if not 35 <= topbar.get("height", 0) <= 37:
        fail(f"Review topbar is not the 36px row: {topbar}")
    for child in (controls, trigger):
        if (
            child.get("y", -1) < topbar.get("y", 0)
            or child.get("y", 0) + child.get("height", 0)
            > topbar.get("y", 0) + topbar.get("height", 0)
        ):
            fail(f"Review comparison control escapes the one-row topbar: {summary}")


session = Session(socket_path)


def focus_foreground_pane(handle, label):
    activation = subprocess.run(["/usr/bin/open", "-a", candidate_app], check=False)
    if activation.returncode != 0:
        fail(f"{label} could not reactivate the packaged candidate")
    session.request("pane.focus", {"handle": handle})
    return wait_for(
        label,
        lambda: session.request("bridge.diff.renderState", {"handle": handle}),
        lambda value: value.get("diagnostics", {}).get("evaluateSucceeded") is True
        and value.get("diagnostics", {}).get("nativeActivity") == "foreground"
        and value.get("summary", {}).get("documentVisibilityState") == "visible",
    )


try:
    login = session.request("auth.login", {"token": token})
    # IPC v2 escrow is reusable until shutdown (IPC escrow and startup diagnostics).
    if login.get("authenticated") is not True or not os.path.isfile(escrow_path):
        fail("Bridge packaged journey IPC escrow was not authenticated or disappeared")
    replay_session = Session(socket_path)
    try:
        replay_login = replay_session.request("auth.login", {"token": token})
        if replay_login.get("authenticated") is not True:
            fail("Bridge packaged journey IPC escrow replay did not authenticate")
    finally:
        replay_session.close()

    session.request("system.identify", {})
    capabilities = session.request("system.capabilities", {})
    methods = capabilities.get("methods", [])
    method_names = {
        entry if isinstance(entry, str) else entry.get("name")
        for entry in methods
        if isinstance(entry, (str, dict))
    }
    required_methods = {
        "workspace.list",
        "pane.list",
        "pane.focus",
        "pane.close",
        "bridge.diff.load",
        "bridge.diff.refresh",
        "bridge.diff.getPackage",
        "bridge.diff.renderState",
        "bridge.diff.selectFile",
        "bridge.diff.scrollToFile",
        "bridge.diff.collapseFile",
        "bridge.diff.expandFile",
        "bridge.fileTree.search",
        "bridge.fileTree.setFilter",
        "bridge.fileTree.revealPath",
        "bridge.telemetry.snapshot",
        "bridge.telemetry.flush",
    }
    missing = sorted(required_methods - method_names)
    if missing:
        fail(f"Bridge packaged journey IPC capabilities are missing: {missing}")

    def fixture_worktree():
        workspaces = session.request("workspace.list", {}).get("workspaces", [])
        for workspace in workspaces:
            for repository in workspace.get("repositories", []):
                for worktree in repository.get("worktrees", []):
                    if canonical(worktree.get("path", "")) == canonical(fixture_root):
                        return worktree
        return None

    worktree = wait_for("fixture workspace registration", fixture_worktree, lambda value: value is not None)
    worktree_id = worktree.get("id")
    if not worktree_id:
        fail("Bridge packaged journey fixture worktree has no canonical id")

    panes = session.request("pane.list", {}).get("panes", [])
    file_pane = next(
        (
            pane
            for pane in panes
            if pane.get("contentKind") == "bridgePanel" and pane.get("worktreeId") == worktree_id
        ),
        None,
    )
    if file_pane is None:
        fail("Bridge packaged journey startup File pane is missing")
    # IPCTargetSelector.swift:19-21 uses bare UUIDs for canonical selectors.
    file_handle = file_pane["id"]

    review_open = session.request("bridge.diff.load", {"worktreeId": worktree_id})
    # AgentStudioIPCBridgeAdapter.swift:37/48 emits a stale handle; IPCTargetSelector.swift:19-21 accepts paneId.
    review_handle = review_open.get("paneId")
    if not isinstance(review_handle, str) or review_handle == file_handle:
        fail("Bridge packaged journey did not create two independent panes")
    focus_foreground_pane(review_handle, "Review pane foreground")

    source_hash_by_path = {}
    corpus_paths = [
        os.fsdecode(relative_path)
        for relative_path in subprocess.check_output(
            [
                git_bin,
                "-C",
                fixture_root,
                "diff",
                "--no-renames",
                "--name-only",
                "-z",
                baseline_commit,
                "--",
            ]
        ).split(b"\0")
        if relative_path
    ]
    if len(corpus_paths) != expected_review_diff_count:
        fail(
            f"Bridge packaged journey corpus count mismatch: "
            f"expected {expected_review_diff_count}, observed {len(corpus_paths)}"
        )
    for relative_path in sentinel_paths:
        absolute_path = os.path.join(fixture_root, relative_path)
        with open(absolute_path, "rb") as file:
            source_hash_by_path[relative_path] = hashlib.sha256(file.read()).hexdigest()
    if set(source_hash_by_path) != set(sentinel_paths):
        fail("Bridge packaged journey failed to hash every traversal sentinel")

    def read_package():
        return session.request("bridge.diff.getPackage", {"handle": review_handle})

    def read_review_page():
        return session.request("bridge.diff.renderState", {"handle": review_handle})

    initial_package = wait_for(
        "initial Review package",
        read_package,
        lambda value: value.get("status") == "ready"
        and value.get("summary", {}).get("filesChanged") == expected_review_diff_count
        and len(value.get("items", [])) == expected_review_diff_count,
    )
    generation_before = initial_package.get("reviewGeneration")
    if not isinstance(generation_before, int):
        fail("Initial Review package has no generation")
    initial_review_page = wait_for(
        "initial Review page metadata",
        read_review_page,
        lambda value: value.get("diagnostics", {}).get("evaluateSucceeded") is True
        and value.get("diagnostics", {}).get("pageErrorCount") == 0
        and value.get("summary", {}).get("activeViewerMode") == "review"
        and value.get("summary", {}).get("reviewMetadataGeneration") == generation_before
        and value.get("summary", {}).get("reviewMetadataItemCount")
        == expected_review_diff_count,
    )

    session.request("bridge.diff.refresh", {"handle": review_handle})

    package = wait_for(
        "refreshed Review package",
        read_package,
        lambda value: value.get("status") == "ready"
        and value.get("summary", {}).get("filesChanged") == expected_review_diff_count
        and len(value.get("items", [])) == expected_review_diff_count
        and value.get("reviewGeneration") is not None
        and value.get("reviewGeneration") > generation_before,
    )
    items_by_path = {item.get("displayPath"): item for item in package.get("items", [])}
    missing_paths = [path for path in sentinel_paths if path not in items_by_path]
    if missing_paths:
        fail(f"Review package omitted traversal sentinels: {missing_paths}")

    review_page = wait_for(
        "refreshed Review page metadata",
        read_review_page,
        lambda value: value.get("diagnostics", {}).get("evaluateSucceeded") is True
        and value.get("diagnostics", {}).get("pageErrorCount") == 0
        and value.get("summary", {}).get("activeViewerMode") == "review"
        and value.get("summary", {}).get("reviewMetadataGeneration")
        == package.get("reviewGeneration")
        and value.get("summary", {}).get("reviewMetadataItemCount")
        == expected_review_diff_count
        and (value.get("summary", {}).get("reviewMetadataTreeRowCount") or 0)
        >= expected_review_diff_count,
    )

    initial_target_oid = git_output("rev-parse", f"refs/heads/{comparison_target_name}")
    initial_reviewed_oid = git_output("rev-parse", f"refs/heads/{reviewed_branch_name}")
    print(
        f"Computer Use must select the comparison target before verification: {comparison_target_name}",
        flush=True,
    )
    selected_package = wait_for(
        "UI-selected contribution target",
        read_package,
        lambda value: value.get("status") == "ready"
        and value.get("reviewGeneration", 0) > package.get("reviewGeneration", 0)
        and has_exact_origin(
            value,
            initial_target_oid,
            initial_reviewed_oid,
            initial_reviewed_oid,
        ),
        attempts=1800,
    )
    review_pane_id = review_open["paneId"]
    wait_for(
        "persisted symbolic comparison target selected through the UI",
        lambda: persisted_comparison_target(review_pane_id),
        lambda value: value
        == {"basis": "commonCommit", "kind": "branch", "name": comparison_target_name},
    )
    generation_before_movement = selected_package.get("reviewGeneration")
    target_before, reviewed_before, target_after, reviewed_after = move_comparison_history()
    if target_before != initial_target_oid or reviewed_before != initial_reviewed_oid:
        fail("Comparison history moved before the automatic-invalidation proof")
    package = wait_for("automatic contribution refresh", read_package, lambda value: value.get("status") == "ready"
        and value.get("reviewGeneration", 0) > generation_before_movement
        and has_exact_origin(value, target_after, reviewed_after, reviewed_after))
    print("Computer Use must open the comparison control after automatic movement", flush=True)
    comparison_render = wait_for(
        "open comparison facts",
        read_review_page,
        lambda value: value.get("summary", {}).get("comparisonTriggerState") == "open"
        and value.get("summary", {}).get("comparisonTargetRevision") == target_after
        and value.get("summary", {}).get("comparisonSharedStartRevision") == reviewed_after,
        attempts=1800,
    )
    if comparison_render.get("summary", {}).get("comparisonTriggerLabel") != f"Compare to: {comparison_target_name}":
        fail(f"Review comparison trigger label is stale: {comparison_render}")
    if not comparison_render.get("summary", {}).get("comparisonTriggerDescription"):
        fail(f"Review comparison trigger description is missing: {comparison_render}")
    require_one_row_geometry(comparison_render)

    invalid_regex_query = "["
    invalid_search = session.request(
        "bridge.fileTree.search",
        {
            "handle": review_handle,
            "searchText": invalid_regex_query,
            "searchMode": {"kind": "regex"},
        },
    )
    require_control(invalid_search, "bridge.fileTree.search")
    if invalid_search.get("treeSearchText") != invalid_regex_query:
        fail("Review invalid-regex Search receipt did not echo the entered candidate")

    maximum_search_text = "x" * 4096
    maximum_search = session.request(
        "bridge.fileTree.search",
        {
            "handle": review_handle,
            "searchText": maximum_search_text,
            "searchMode": {"kind": "text"},
        },
    )
    require_control(maximum_search, "bridge.fileTree.search")
    if maximum_search.get("treeSearchText") != maximum_search_text:
        fail("Review maximum-length Search receipt did not echo the admitted candidate")

    oversized_search_text = "x" * 4097
    oversized_error = session.request_error(
        "bridge.fileTree.search",
        {
            "handle": review_handle,
            "searchText": oversized_search_text,
            "searchMode": {"kind": "text"},
        },
    )
    if oversized_error.get("code") != -32602:
        fail("Review oversized Search was not rejected as invalid params")

    cleared_search = session.request(
        "bridge.fileTree.search",
        {"handle": review_handle, "searchText": "", "searchMode": {"kind": "text"}},
    )
    require_control(cleared_search, "bridge.fileTree.search")
    if cleared_search.get("treeSearchText") != "":
        fail(f"Review Search did not clear after boundary checks: {cleared_search}")

    for position, relative_path in zip(("early", "middle", "final"), sentinel_paths):
        item = items_by_path[relative_path]
        item_id = item.get("itemId")
        query = os.path.basename(relative_path)
        search = session.request(
            "bridge.fileTree.search",
            {"handle": review_handle, "searchText": query, "searchMode": {"kind": "text"}},
        )
        require_control(search, "bridge.fileTree.search")
        if search.get("treeSearchText") != query:
            fail(f"Review {position} search receipt is stale: {search}")
        filter_result = session.request(
            "bridge.fileTree.setFilter",
            {
                "handle": review_handle,
                "candidate": {
                    "surface": "review",
                    "gitStatusFilter": "all",
                    "categoryFilter": "all",
                    "showBinary": True,
                    "showLarge": True,
                },
            },
        )
        require_filter_control(filter_result, "review")
        reveal = session.request(
            "bridge.fileTree.revealPath", {"handle": review_handle, "path": relative_path}
        )
        require_control(reveal, "bridge.fileTree.revealPath", item_id=item_id, path=relative_path)
        selected = session.request(
            "bridge.diff.selectFile", {"handle": review_handle, "itemId": item_id}
        )
        if selected.get("selected") is not True or selected.get("itemId") != item_id:
            fail(f"Review {position} select failed: {selected}")
        scroll = session.request(
            "bridge.diff.scrollToFile", {"handle": review_handle, "itemId": item_id}
        )
        require_control(scroll, "bridge.diff.scrollToFile", item_id=item_id)
        collapsed = session.request(
            "bridge.diff.collapseFile", {"handle": review_handle, "itemId": item_id}
        )
        require_control(collapsed, "bridge.diff.collapseFile", item_id=item_id)
        expanded = session.request(
            "bridge.diff.expandFile", {"handle": review_handle, "itemId": item_id}
        )
        require_control(expanded, "bridge.diff.expandFile", item_id=item_id)

        def selected_render_state():
            return session.request("bridge.diff.renderState", {"handle": review_handle})

        wait_for(
            f"Review {position} painted selection",
            selected_render_state,
            lambda value: value.get("diagnostics", {}).get("evaluateSucceeded") is True
            and value.get("diagnostics", {}).get("pageErrorCount") == 0
            and value.get("summary", {}).get("activeViewerMode") == "review"
            and value.get("summary", {}).get("documentVisibilityState") == "visible"
            and value.get("summary", {}).get("frameLivenessRafAlive") == "true"
            and value.get("summary", {}).get("reviewSelectedItemId") == item_id
            and (value.get("summary", {}).get("reviewCodeTextLength") or 0) > 0,
        )
        selected_package = read_package()
        if selected_package.get("selectedItemId") != item_id:
            fail(f"Review {position} native selection diverged from DOM selection")

    focus_foreground_pane(file_handle, "File pane foreground")

    def read_file_page():
        return session.request("bridge.diff.renderState", {"handle": file_handle})

    wait_for(
        "File page metadata",
        read_file_page,
        lambda value: value.get("diagnostics", {}).get("evaluateSucceeded") is True
        and value.get("diagnostics", {}).get("pageErrorCount") == 0
        and value.get("summary", {}).get("activeViewerMode") == "file"
        and value.get("summary", {}).get("documentVisibilityState") == "visible"
        and value.get("summary", {}).get("frameLivenessRafAlive") == "true"
        and (value.get("summary", {}).get("worktreeDescriptorCount") or 0)
        == value.get("summary", {}).get("worktreeTotalDescriptorCount")
        and (value.get("summary", {}).get("worktreeDescriptorCount") or 0)
        >= expected_file_count,
    )

    file_filter_result = session.request(
        "bridge.fileTree.setFilter",
        {
            "handle": file_handle,
            "candidate": {
                "surface": "files",
                "categoryFilter": "all",
            },
        },
    )
    require_filter_control(file_filter_result, "files")

    def reveal_final_file():
        return session.request(
            "bridge.fileTree.revealPath", {"handle": file_handle, "path": sentinel_paths[-1]}
        )

    final_reveal = wait_for(
        "File final-path reveal",
        reveal_final_file,
        lambda value: value.get("status") == "accepted" and value.get("path") == sentinel_paths[-1],
    )
    require_control(final_reveal, "bridge.fileTree.revealPath", path=sentinel_paths[-1])
    final_search = session.request(
        "bridge.fileTree.search",
        {
            "handle": file_handle,
            "searchText": os.path.basename(sentinel_paths[-1]),
            "searchMode": {"kind": "text"},
        },
    )
    require_control(final_search, "bridge.fileTree.search")

    def final_file_render_state():
        return session.request("bridge.diff.renderState", {"handle": file_handle})

    wait_for(
        "File final-path painted content",
        final_file_render_state,
        lambda value: value.get("diagnostics", {}).get("evaluateSucceeded") is True
        and value.get("diagnostics", {}).get("pageErrorCount") == 0
        and value.get("summary", {}).get("activeViewerMode") == "file"
        and value.get("summary", {}).get("documentVisibilityState") == "visible"
        and value.get("summary", {}).get("frameLivenessRafAlive") == "true"
        and value.get("summary", {}).get("worktreeRenderedFilePath") == sentinel_paths[-1]
        and value.get("summary", {}).get("worktreeOpenFilePath") == sentinel_paths[-1]
        and value.get("summary", {}).get("worktreeOpenFileState") == "ready"
        and (value.get("summary", {}).get("worktreeCodeTextLength") or 0) > 0,
    )

    for label, handle in (("Review", review_handle), ("File", file_handle)):
        focus_foreground_pane(handle, f"{label} pane telemetry foreground")
        snapshot = session.request("bridge.telemetry.snapshot", {"handle": handle})
        if snapshot.get("kind") != "report":
            fail(f"Bridge telemetry snapshot unavailable for {handle}: {snapshot}")
        flushed = session.request("bridge.telemetry.flush", {"handle": handle})
        if flushed.get("kind") != "report" or flushed.get("drained") is not True:
            fail(f"Bridge telemetry did not drain/reopen for {handle}: {flushed}")

    session.request("pane.close", {"handle": review_handle})
    marker = os.environ.get("AGENTSTUDIO_BRIDGE_JOURNEY_MARKER", "")
    proof_token = os.environ.get("AGENTSTUDIO_BRIDGE_JOURNEY_PROOF_TOKEN", "")
    if not marker or not proof_token:
        fail("Bridge packaged journey is missing Victoria marker/proof-token binding")
    print(
        json.dumps(
            {
                "filePane": file_handle,
                "reviewPane": review_handle,
                "reviewGeneration": package.get("reviewGeneration"),
                "filesChanged": package.get("summary", {}).get("filesChanged"),
                "sentinelSha256": source_hash_by_path,
            },
            sort_keys=True,
        )
    )
finally:
    session.close()
PY

final_review_diff_count="$(
  "$GIT_BIN" -C "$fixture_root" diff --no-renames --name-only "$baseline_commit" -- \
    | awk 'NF { count += 1 } END { print count + 0 }'
)"
if [ "$final_review_diff_count" -ne "$expected_review_diff_count" ]; then
  echo "Bridge packaged journey mutated the fixture Review diff: expected $expected_review_diff_count, observed $final_review_diff_count" >&2
  exit 1
fi
final_fixture_digest="$(fixture_digest_for_current_worktree "$fixture_root" "$baseline_commit")"
if [ "$final_fixture_digest" != "$expected_fixture_digest" ]; then
  echo "Bridge packaged journey mutated the fixture contents" >&2
  exit 1
fi

echo "Bridge packaged LaunchServices product journey PASS"
echo "pid=$state_pid"
echo "app=$state_app"
echo "fixture=$fixture_root"
echo "candidate remains available for Computer Use visual proof"
