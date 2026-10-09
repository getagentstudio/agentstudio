#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_FILE="${AGENTSTUDIO_OBSERVABILITY_STATE_FILE:-$PROJECT_ROOT/tmp/debug-observability/latest-observability.env}"

state_status=""
state_pid=""
state_data_dir=""
state_activation_mode=""
state_ipc_auth_mode=""

if [ -f "$STATE_FILE" ]; then
  while IFS='=' read -r key value; do
    decoded_value="$(
      /usr/bin/python3 - "$value" <<'PY'
import shlex
import sys

try:
    parsed = shlex.split(sys.argv[1])
except ValueError:
    parsed = []
print(parsed[0] if parsed else "")
PY
    )"
    case "$key" in
      AGENTSTUDIO_OBSERVABILITY_STATUS)
        state_status="$decoded_value"
        ;;
      AGENTSTUDIO_OBSERVABILITY_PID)
        state_pid="$decoded_value"
        ;;
      AGENTSTUDIO_OBSERVABILITY_DATA_DIR)
        state_data_dir="$decoded_value"
        ;;
      AGENTSTUDIO_OBSERVABILITY_ACTIVATION_MODE)
        state_activation_mode="$decoded_value"
        ;;
      AGENTSTUDIO_OBSERVABILITY_IPC_AUTH_MODE)
        state_ipc_auth_mode="$decoded_value"
        ;;
    esac
  done <"$STATE_FILE"
fi

if [ "$state_status" != "running" ]; then
  echo "AgentStudio debug observability state is not running: ${state_status:-<missing>}" >&2
  echo "state file: $STATE_FILE" >&2
  exit 1
fi

case "$state_pid" in
  ''|*[!0-9]*)
    echo "AgentStudio debug observability state missing numeric PID" >&2
    echo "state file: $STATE_FILE" >&2
    exit 1
    ;;
esac

if ! kill -0 "$state_pid" >/dev/null 2>&1; then
  echo "AgentStudio debug observability PID is not running: $state_pid" >&2
  echo "state file: $STATE_FILE" >&2
  exit 1
fi

if [ -z "$state_data_dir" ]; then
  echo "AgentStudio debug observability state missing data directory" >&2
  echo "state file: $STATE_FILE" >&2
  exit 1
fi

if [ "$state_ipc_auth_mode" != "authenticated" ]; then
  echo "AgentStudio IPC phase-a smoke requires authenticated IPC auth mode: ${state_ipc_auth_mode:-<missing>}" >&2
  echo "state file: $STATE_FILE" >&2
  exit 1
fi

if [ "$state_activation_mode" != "background" ]; then
  echo "AgentStudio IPC phase-a smoke requires background activation mode: ${state_activation_mode:-<missing>}" >&2
  echo "state file: $STATE_FILE" >&2
  exit 1
fi

AGENTSTUDIO_OBSERVABILITY_IPC_METADATA="${AGENTSTUDIO_OBSERVABILITY_IPC_METADATA:-$state_data_dir/ipc/runtime.json}"
IPC_DEBUG_ESCROW_PATH="${AGENTSTUDIO_IPC_DEBUG_TOKEN_ESCROW:-}"
case "$IPC_DEBUG_ESCROW_PATH" in
  /*) ;;
  *)
    echo "Set AGENTSTUDIO_IPC_DEBUG_TOKEN_ESCROW to the absolute escrow path used to launch the debug app." >&2
    exit 1
    ;;
esac

if [ ! -f "$AGENTSTUDIO_OBSERVABILITY_IPC_METADATA" ]; then
  echo "AgentStudio IPC runtime metadata is missing: $AGENTSTUDIO_OBSERVABILITY_IPC_METADATA" >&2
  exit 1
fi

if [ ! -s "$IPC_DEBUG_ESCROW_PATH" ]; then
  echo "AgentStudio IPC debug escrow is missing: AGENTSTUDIO_IPC_DEBUG_TOKEN_ESCROW=$IPC_DEBUG_ESCROW_PATH" >&2
  echo "Launch with AGENTSTUDIO_IPC_DEBUG_TOKEN_ESCROW set to this absolute path before running this verifier." >&2
  exit 1
fi

/usr/bin/python3 - "$AGENTSTUDIO_OBSERVABILITY_IPC_METADATA" "$IPC_DEBUG_ESCROW_PATH" <<'PY'
import json
import os
import socket
import sys
import uuid

metadata_path = sys.argv[1]
escrow_path = sys.argv[2]
response_timeout_seconds = float(os.environ.get("AGENTSTUDIO_IPC_PHASE_A_SMOKE_RESPONSE_TIMEOUT_SECONDS", "15"))

with open(metadata_path, "r", encoding="utf-8") as metadata_file:
    metadata = json.load(metadata_file)
socket_path = metadata.get("socketPath")
if not socket_path:
    print(f"IPC metadata missing socketPath: {metadata_path}", file=sys.stderr)
    sys.exit(1)

with open(escrow_path, "r", encoding="utf-8") as escrow_file:
    escrow = json.load(escrow_file)
debug_token = escrow.get("token")
if not isinstance(debug_token, str) or not debug_token:
    print(f"AgentStudio IPC debug escrow has no token: AGENTSTUDIO_IPC_DEBUG_TOKEN_ESCROW={escrow_path}", file=sys.stderr)
    sys.exit(1)
if (escrow.get("socketPath") != socket_path or not escrow.get("runtimeId")
        or escrow.get("runtimeId") != metadata.get("runtimeId")):
    print("AGENTSTUDIO_IPC_DEBUG_TOKEN_ESCROW does not match IPC metadata", file=sys.stderr)
    sys.exit(1)


class JSONRPCSession:
    def __init__(self, path):
        self.socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.socket.settimeout(response_timeout_seconds)
        self.socket.connect(path)
        self.reader = self.socket.makefile("rb")

    def close(self):
        self.reader.close()
        self.socket.close()

    def request(self, request_id, method, params):
        payload = {
            "jsonrpc": "2.0",
            "id": request_id,
            "method": method,
            "params": params,
        }
        self.socket.sendall((json.dumps(payload, separators=(",", ":")) + "\n").encode("utf-8"))
        while True:
            try:
                line = self.reader.readline()
            except socket.timeout:
                print(
                    f"IPC response timed out after {response_timeout_seconds:g}s for {method}",
                    file=sys.stderr,
                )
                sys.exit(1)
            if not line:
                print(f"IPC socket closed before response for {method}", file=sys.stderr)
                sys.exit(1)
            response = json.loads(line.decode("utf-8"))
            if response.get("id") == request_id:
                return response


def require_success(response, label):
    if response.get("error") is not None:
        print(f"{label} failed: {response['error']}", file=sys.stderr)
        sys.exit(1)
    return response.get("result", {})


def require_error(response, label, expected_code, expected_message):
    error = response.get("error")
    if error is None:
        print(f"{label} unexpectedly succeeded: {response.get('result', {})}", file=sys.stderr)
        sys.exit(1)
    if error.get("code") != expected_code or error.get("message") != expected_message:
        print(
            f"{label} returned unexpected error: {error}; "
            f"expected code={expected_code} message={expected_message!r}",
            file=sys.stderr,
        )
        sys.exit(1)
    return error


session = JSONRPCSession(socket_path)
try:
    login_result = require_success(
        session.request(1, "auth.login", {"token": debug_token}),
        "auth.login",
    )
    if login_result.get("authenticated") is not True:
        print(f"auth.login did not authenticate: {login_result}", file=sys.stderr)
        sys.exit(1)
    # IPC v2 escrow is reusable until shutdown (IPC escrow and startup diagnostics).
    if not os.path.isfile(escrow_path):
        print(f"AgentStudio IPC debug escrow disappeared: AGENTSTUDIO_IPC_DEBUG_TOKEN_ESCROW={escrow_path}", file=sys.stderr)
        sys.exit(1)

    replay_session = JSONRPCSession(socket_path)
    try:
        replay_result = require_success(
            replay_session.request(900, "auth.login", {"token": debug_token}),
            "auth.login replay",
        )
        if replay_result.get("authenticated") is not True:
            print("auth.login replay did not authenticate", file=sys.stderr)
            sys.exit(1)
    finally:
        replay_session.close()

    tampered_token = ("A" if debug_token[0] != "A" else "B") + debug_token[1:]
    denied_session = JSONRPCSession(socket_path)
    try:
        require_error(
            denied_session.request(901, "auth.login", {"token": tampered_token}),
            "auth.login tampered credential",
            -32001,
            "unauthenticated",
        )
    finally:
        denied_session.close()

    capabilities = require_success(
        session.request(2, "system.capabilities", {}),
        "system.capabilities",
    )
    methods = capabilities.get("methods", [])
    if not any(method.get("name") == "pane.snapshot" for method in methods):
        print("pane.snapshot missing from system.capabilities", file=sys.stderr)
        sys.exit(1)

    panes_result = require_success(
        session.request(3, "pane.list", {}),
        "pane.list",
    )
    panes = panes_result.get("panes", [])
    ordinal_one = next((pane for pane in panes if pane.get("ordinal") == 1), None)
    if ordinal_one is None:
        print("pane:1 is not available in pane.list result", file=sys.stderr)
        sys.exit(1)
    pane_id = ordinal_one.get("id")
    if not pane_id:
        print("pane:1 result is missing a canonical id", file=sys.stderr)
        sys.exit(1)
    # IPCTargetSelector.swift:19-21 uses bare UUIDs for canonical selectors.
    canonical_pane_handle = pane_id

    friendly_snapshot = require_success(
        session.request(4, "pane.snapshot", {"handle": "pane:1"}),
        "pane.snapshot pane:1",
    )
    friendly_pane_id = friendly_snapshot.get("pane", {}).get("id")
    if friendly_pane_id != canonical_pane_handle:
        print("pane.snapshot pane:1 did not resolve to the expected canonical pane", file=sys.stderr)
        sys.exit(1)

    canonical_snapshot = require_success(
        session.request(5, "pane.snapshot", {"handle": canonical_pane_handle}),
        "pane.snapshot canonical handle",
    )
    canonical_result_pane_id = canonical_snapshot.get("pane", {}).get("id")
    if canonical_result_pane_id != canonical_pane_handle:
        print("pane.snapshot canonical result does not match requested pane", file=sys.stderr)
        sys.exit(1)

    window_list = require_success(session.request(902, "window.list", {}), "window.list")
    windows = window_list.get("windows", [])
    if len(windows) != 1:
        print(f"IPC phase-a smoke requires exactly one workspace window; got {len(windows)}", file=sys.stderr)
        sys.exit(1)
    workspace_window_arguments = {"workspaceWindowId": str(uuid.UUID(windows[0]["id"]))}

    command_list = require_success(
        session.request(6, "command.list", {}),
        "command.list",
    )
    commands = command_list.get("commands", [])
    if not commands:
        print("command.list returned no commands", file=sys.stderr)
        sys.exit(1)
    command_bar_entry = next(
        (
            command
            for command in commands
            if command.get("id") == "showCommandBarCommands"
        ),
        None,
    )
    if command_bar_entry is None:
        print("command.list did not include showCommandBarCommands", file=sys.stderr)
        sys.exit(1)
    if command_bar_entry.get("title") != "Command Palette":
        print(f"showCommandBarCommands title mismatch: {command_bar_entry}", file=sys.stderr)
        sys.exit(1)
    repo_sort_toggle_entry = next(
        (
            command
            for command in commands
            if command.get("id") == "toggleReposSortDirection"
        ),
        None,
    )
    if repo_sort_toggle_entry is None:
        print("command.list did not include toggleReposSortDirection", file=sys.stderr)
        sys.exit(1)
    def requires_workspace_window(command_entry):
        schema = command_entry.get("argumentSchema", {})
        properties = schema.get("properties", {})
        # IPCCommandArguments+Schemas.swift:37; IPCSchemaProviding.swift:17 uses a UUID pattern.
        return (
            command_entry.get("argumentVariants") == ["workspaceWindow"]
            and schema.get("type") == "object"
            and set(schema.get("required", [])) == {"kind", "workspaceWindowId"}
            and set(properties) == {"kind", "workspaceWindowId"}
            and properties.get("kind", {}).get("enum") == ["workspaceWindow"]
            and properties.get("workspaceWindowId", {}).get("type") == "string"
            and properties.get("workspaceWindowId", {}).get("pattern")
                == "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
            and schema.get("additionalProperties") is False
        )

    # AppCommand+IPCProjection.swift:81 requires the workspaceWindow argument variant.
    if not requires_workspace_window(repo_sort_toggle_entry):
        print(
            f"toggleReposSortDirection argument schema mismatch: {repo_sort_toggle_entry}",
            file=sys.stderr,
        )
        sys.exit(1)
    required_sidebar_workspace_window_commands = {
        "showReposSidebar",
        "showPanesSidebar",
        "setReposGroupingRepo",
        "setReposGroupingActivity",
        "setReposSortFieldName",
        "setReposSortFieldActivity",
        "toggleReposSortDirection",
        "toggleReposShowsPinned",
        "togglePanesShowsPinned",
    }
    retired_panes_organization_commands = {
        "setPanesSortFieldName",
        "setPanesSortFieldActivity",
        "togglePanesSortDirection",
    }
    removed_panes_organization_commands = {
        "setPanesGroupingRepo", "setPanesGroupingTab", "setPanesGroupingActivity",
        "setPanesSubgroupNone", "setPanesSubgroupActivity",
    }
    commands_by_id = {command.get("id"): command for command in commands}
    for command_id in removed_panes_organization_commands:
        if command_id in commands_by_id:
            print(f"removed Panes command remains in command.list: {command_id}", file=sys.stderr)
            sys.exit(1)
    for command_id in sorted(required_sidebar_workspace_window_commands):
        command_entry = commands_by_id.get(command_id)
        if command_entry is None:
            print(f"command.list did not include {command_id}", file=sys.stderr)
            sys.exit(1)
        # AppCommand+IPCProjection.swift:81 requires the workspaceWindow argument variant.
        if not requires_workspace_window(command_entry):
            print(f"{command_id} must require a workspaceWindowId UUID argument: {command_entry}", file=sys.stderr)
            sys.exit(1)
    for command_id in sorted(retired_panes_organization_commands):
        command_entry = commands_by_id.get(command_id)
        if command_entry is None:
            print(f"command.list omitted retained retired command {command_id}", file=sys.stderr)
            sys.exit(1)
        # AppCommand+IPCProjection.swift:25,242,327,459 declares headless/unavailable and these privileges.
        if (command_entry.get("executionMode") != "headless"
                or set(command_entry.get("requiredPrivileges", [])) != {"appCommandExecute", "sidebarStateMutate"}
                or command_entry.get("resultVariants") != ["unavailable"]):
            print(f"retired command IPC descriptor mismatch: {command_entry}", file=sys.stderr)
            sys.exit(1)
    allowed_command_keys = {
        "id",
        "title",
        "description",
        "exposure",
        "executionMode",
        "argumentVariants",
        "requiredPrivileges",
        "argumentSchema",
        "dataScope",
        "allowedTargetKinds",
        "resultVariants",
        "resultSchema",
        "examples",
        "agentEligibility",
    }
    for command in commands:
        unexpected_keys = set(command.keys()) - allowed_command_keys
        missing_keys = allowed_command_keys - set(command.keys())
        # IPCCommandDescriptor.swift:87 declares this exact typed catalog key set.
        if unexpected_keys or missing_keys:
            print(
                f"command.list descriptor keys mismatch: unexpected={sorted(unexpected_keys)} missing={sorted(missing_keys)}: {command}",
                file=sys.stderr,
            )
            sys.exit(1)

    command_bar_result = require_success(
        session.request(
            7,
            "command.execute",
            {"commandId": "showCommandBarCommands", "correlationId": str(uuid.uuid4()), "arguments": workspace_window_arguments},
        ),
        "command.execute showCommandBarCommands",
    )
    # AppDelegate+HeadlessIPCCommandHandling.swift:79 reports presentation in debug.
    if command_bar_result.get("kind") != "presented":
        print(f"showCommandBarCommands did not present: {command_bar_result}", file=sys.stderr)
        sys.exit(1)

    show_repos_result = require_success(
        session.request(
            8,
            "command.execute",
            {"commandId": "showReposSidebar", "correlationId": str(uuid.uuid4()), "arguments": workspace_window_arguments},
        ),
        "command.execute showReposSidebar before repo settings",
    )
    # IPCCommandExecutionResult.swift:204 encodes the kind discriminator.
    if show_repos_result.get("kind") != "applied":
        print(f"showReposSidebar did not apply: {show_repos_result}", file=sys.stderr)
        sys.exit(1)

    repo_sort_first_toggle = require_success(
        session.request(
            9,
            "command.execute",
            {
                "commandId": "toggleReposSortDirection",
                "correlationId": str(uuid.uuid4()),
                "arguments": workspace_window_arguments,
            },
        ),
        "command.execute toggleReposSortDirection first toggle",
    )
    # IPCCommandExecutionResult.swift:204 encodes the kind discriminator.
    if repo_sort_first_toggle.get("kind") != "applied":
        print(f"first repo sort toggle did not apply: {repo_sort_first_toggle}", file=sys.stderr)
        sys.exit(1)

    repo_sort_second_toggle = require_success(
        session.request(
            10,
            "command.execute",
            {
                "commandId": "toggleReposSortDirection",
                "correlationId": str(uuid.uuid4()),
                "arguments": workspace_window_arguments,
            },
        ),
        "command.execute toggleReposSortDirection second toggle",
    )
    # IPCCommandExecutionResult.swift:204 encodes the kind discriminator.
    if repo_sort_second_toggle.get("kind") != "applied":
        print(f"second repo sort toggle did not apply: {repo_sort_second_toggle}", file=sys.stderr)
        sys.exit(1)

    # AgentStudioAppIPCRequestError.swift:18 reports -32602 invalid arguments.
    extraneous_order_error = require_error(
        session.request(
            11,
            "command.execute",
            {
                "commandId": "toggleReposSortDirection",
                "correlationId": str(uuid.uuid4()),
                "arguments": {**workspace_window_arguments, "order": "currentRepoOrder"},
            },
        ),
        "command.execute toggleReposSortDirection extraneous order",
        -32602,
        "invalid arguments",
    )
    # AgentStudioAppIPCRequestError.swift:16 and AppCommandRawArgumentParser.swift:29 reject the extra field.
    if extraneous_order_error.get("data") != {
        "reason": "invalidArguments", "fieldPath": "$.arguments.order", "expected": "only declared fields",
    }:
        print(f"extraneous order rejection data mismatch: {extraneous_order_error}", file=sys.stderr)
        sys.exit(1)

    # ipc-catalog-15211f2b3.json: ui.commandBar.open requires window and correlation UUIDs.
    command_bar_open = require_success(
        session.request(
            12,
            "ui.commandBar.open",
            {
                "workspaceWindowId": workspace_window_arguments["workspaceWindowId"],
                "scope": "commands",
                "correlationId": str(uuid.uuid4()),
            },
        ),
        "ui.commandBar.open commands",
    )
    if command_bar_open.get("scope") != "commands":
        print(f"ui.commandBar.open did not report commands scope: {command_bar_open}", file=sys.stderr)
        sys.exit(1)
    if not command_bar_open.get("workspaceWindowId"):
        print(f"ui.commandBar.open result missing workspaceWindowId: {command_bar_open}", file=sys.stderr)
        sys.exit(1)

    def execute_sidebar_command(request_id, command_id, expected_kind="applied"):
        # AppCommand+IPCProjection.swift:79,81 separates targetless Inbox from window-scoped sidebar commands.
        command_arguments = {} if command_id not in required_sidebar_workspace_window_commands else workspace_window_arguments
        result = require_success(
            session.request(
                request_id,
                "command.execute",
                {"commandId": command_id, "correlationId": str(uuid.uuid4()), "arguments": command_arguments},
            ),
            f"command.execute {command_id}",
        )
        # IPCCommandExecutionResult.swift:204 carries the exact requested result kind.
        if result.get("kind") != expected_kind:
            print(f"{command_id} did not return {expected_kind}: {result}", file=sys.stderr)
            sys.exit(1)
        # AppDelegate+HeadlessIPCCommandHandling.swift:39-46 keeps dormant Inbox commands unavailable.
        if expected_kind == "unavailable" and result.get("reason") != "featureUnavailable":
            print(f"{command_id} did not report featureUnavailable: {result}", file=sys.stderr)
            sys.exit(1)

    sidebar_command_expectations = [
        (13, "setReposGroupingRepo"),
        (14, "setReposGroupingActivity"),
        (15, "setReposGroupingRepo"),
        (16, "setReposSortFieldName"),
        (17, "setReposSortFieldActivity"),
        (18, "toggleReposShowsPinned"),
        (19, "toggleReposShowsPinned"),
        (20, "showPanesSidebar"),
        (30, "togglePanesShowsPinned"),
        (31, "togglePanesShowsPinned"),
    ]
    for request_id, command_id in sidebar_command_expectations:
        execute_sidebar_command(request_id, command_id)

    panes_grouping_before_retired_commands = require_success(
        session.request(37, "sidebar.grouping.get", {"surface": "panes"}),
        "sidebar.grouping.get panes before retired commands",
    )
    if panes_grouping_before_retired_commands.get("mode") != "activity":
        print(
            f"Panes grouping did not use fixed activity mode: {panes_grouping_before_retired_commands}",
            file=sys.stderr,
        )
        sys.exit(1)

    for request_id, command_id in enumerate(sorted(retired_panes_organization_commands), start=40):
        retired_result = require_success(
            session.request(
                request_id,
                "command.execute",
                {"commandId": command_id, "correlationId": str(uuid.uuid4()), "arguments": workspace_window_arguments},
            ),
            f"command.execute retired {command_id}",
        )
        # AppDelegate+HeadlessIPCCommandHandling.swift:60 leaves retired Panes settings unavailable.
        if retired_result.get("kind") != "unavailable" or retired_result.get("reason") != "featureUnavailable":
            print(f"retired Panes command outcome mismatch: {retired_result}", file=sys.stderr)
            sys.exit(1)

    panes_grouping_after_retired_commands = require_success(
        session.request(48, "sidebar.grouping.get", {"surface": "panes"}),
        "sidebar.grouping.get panes after retired commands",
    )
    if panes_grouping_after_retired_commands != panes_grouping_before_retired_commands:
        print(
            "retired Panes organization commands mutated fixed Panes state: "
            f"before={panes_grouping_before_retired_commands} after={panes_grouping_after_retired_commands}",
            file=sys.stderr,
        )
        sys.exit(1)

    repo_grouping_before_inbox_commands = require_success(
        session.request(903, "sidebar.grouping.get", {"surface": "repo"}),
        "sidebar.grouping.get repo before dormant Inbox commands",
    )
    # AgentStudioIPCSidebarAdapter.swift:25 and AgentStudioAppIPCRequestError.swift:196 reject dormant Inbox reads.
    inbox_grouping_before_inbox_commands = require_error(
        session.request(904, "sidebar.grouping.get", {"surface": "inbox"}),
        "sidebar.grouping.get inbox before dormant Inbox commands",
        -32004,
        "target not found",
    )
    sidebar_surface_before_inbox_commands = require_success(
        session.request(905, "sidebar.surface.get", {}),
        "sidebar.surface.get before dormant Inbox commands",
    )

    inbox_command_expectations = [
        (32, "showInboxNotifications"),
        (33, "setInboxGroupingTab"),
        (34, "setInboxGroupingRepo"),
        (35, "setInboxGroupingPane"),
        (36, "setInboxGroupingNone"),
    ]
    for request_id, command_id in inbox_command_expectations:
        execute_sidebar_command(request_id, command_id, expected_kind="unavailable")

    repo_grouping = require_success(
        session.request(49, "sidebar.grouping.get", {"surface": "repo"}),
        "sidebar.grouping.get repo",
    )
    if repo_grouping.get("mode") != "repo":
        print(f"repo grouping did not persist repository mode: {repo_grouping}", file=sys.stderr)
        sys.exit(1)
    # AppDelegate+HeadlessIPCCommandHandling.swift:39-46 leaves grouping unchanged for dormant Inbox commands.
    if repo_grouping != repo_grouping_before_inbox_commands:
        print("dormant Inbox commands mutated Repos grouping", file=sys.stderr)
        sys.exit(1)

    # AgentStudioIPCSidebarAdapter.swift:25 and AgentStudioAppIPCRequestError.swift:196 reject dormant Inbox reads.
    inbox_grouping = require_error(
        session.request(50, "sidebar.grouping.get", {"surface": "inbox"}),
        "sidebar.grouping.get inbox",
        -32004,
        "target not found",
    )
    # AppDelegate+HeadlessIPCCommandHandling.swift:39-46 leaves grouping unchanged for dormant Inbox commands.
    if inbox_grouping != inbox_grouping_before_inbox_commands:
        print("dormant Inbox commands changed Inbox grouping unavailability", file=sys.stderr)
        sys.exit(1)

    sidebar_surface = require_success(
        session.request(51, "sidebar.surface.get", {}),
        "sidebar.surface.get",
    )
    # AppDelegate+HeadlessIPCCommandHandling.swift:39-46 does not revive an Inbox surface.
    if sidebar_surface != sidebar_surface_before_inbox_commands:
        print("dormant Inbox commands mutated the visible sidebar surface", file=sys.stderr)
        sys.exit(1)

    panes_grouping_after_inbox_commands = require_success(
        session.request(906, "sidebar.grouping.get", {"surface": "panes"}),
        "sidebar.grouping.get panes after dormant Inbox commands",
    )
    # AppDelegate+HeadlessIPCCommandHandling.swift:39-46 leaves grouping unchanged for dormant Inbox commands.
    if panes_grouping_after_inbox_commands != panes_grouping_after_retired_commands:
        print("dormant Inbox commands mutated Panes grouping", file=sys.stderr)
        sys.exit(1)

    require_error(
        session.request(
            52,
            "sidebar.grouping.set",
            {"surface": "repo", "mode": "none"},
        ),
        "sidebar.grouping.set removed route",
        -32601,
        "method not found",
    )

    print(f"AgentStudio IPC Phase A smoke passed for {canonical_pane_handle}")
finally:
    session.close()
PY
