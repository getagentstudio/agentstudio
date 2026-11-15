#!/bin/bash
# Build synthetic pane-context requests for the real IPC adapter. Prints JSON
# only: never calls a CLI/app, invents a binding, or reads a credential.
set -euo pipefail
CONTEXT_INPUT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

context_input_help() {
  cat <<'HELP'
pane-context-input.sh --help | --self-test
pane-context-input.sh form single|multiple|freeText|elicitation|approval ENVELOPE_JSON
pane-context-input.sh hook permission|question-summary|close-question ENVELOPE_JSON

form envelope: handle, messageId, writer:{provider,conversationId}, correlationId.
hook envelope: handle, provider:{identifier,version,mode}, correlationId,
event:{conversationId,turnId,occurrenceId,elicitationId?}.
Supply fresh repository-generated UUIDv7s and the owned fixture's actual writer
and provider identity. The helper never generates identities. Output is a
complete pane.message.send or session.event request, not a delivery receipt.
Send from the declared fixture shell only after its mutation grant; retain
admission plus owner readback. Approval requires the delivered P6 wire schema.
Permission deliberately has NO summary. question-summary is an elicitation,
never an approval. Real S16a and exact S18 remain UNKNOWN; do not fake them.
HELP
}

context_form() {
  local form_kind="$1" envelope="$2"
  jq -e --arg kind "$form_kind" '
    def uuid7: type=="string" and test("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-7[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$");
    if .handle=="self" and (.messageId|uuid7)
      and (.correlationId|uuid7) and (.writer.provider|type=="string" and length>0)
      and (.writer.conversationId|type=="string" and length>0)
      and ((.writer|keys)-["provider","conversationId"]|length==0)
      and ((keys - ["handle","messageId","writer","correlationId"])|length==0)
    then . else error("Need the owned writer envelope and fresh UUIDv7s") end |
    .importance="attention" | .actions=[] |
    .shape={kind:"ask",reason:(if $kind=="approval" then "approval" else "question" end),waiting:{kind:"nonBlocking"}} |
    if $kind=="single" then
      .body="Pick a color for the test?" |
      .shape.form={kind:"choice",options:[{id:"red",label:"red"},{id:"blue",label:"blue"}],allowsMultiple:false}
    elif $kind=="multiple" then
      .body="Which suites should I rerun?" |
      .shape.form={kind:"choice",options:[{id:"swift",label:"Swift"},{id:"bridge",label:"BridgeWeb"},{id:"e2e",label:"E2E"}],allowsMultiple:true}
    elif $kind=="freeText" then .body="Describe the next step" | .shape.form={kind:"freeText",placeholder:"Reply"}
    elif $kind=="elicitation" then .body="Choose the migration settings" |
      .shape.form={kind:"elicitation",schema:{properties:[{name:"environment",title:"Environment",type:{kind:"string",choices:["staging","local"]}},{name:"dryRun",title:"Dry run",type:{kind:"boolean"}}],required:["environment","dryRun"]}}
    elif $kind=="approval" then .body="Approve running the migration?" | .shape.form={kind:"approval"}
    else error("Unknown form kind") end
  ' <<< "$envelope"
}

context_hook() {
  local hook_kind="$1" envelope="$2"
  jq -e --arg kind "$hook_kind" '
    def uuid7: type=="string" and test("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-7[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$");
    if .handle=="self" and (.correlationId|uuid7)
      and (.event.occurrenceId|uuid7) and (.event.conversationId|type=="string" and length>0)
      and (.event.turnId|type=="string" and length>0)
      and all(.provider.identifier,.provider.version,.provider.mode; type=="string" and length>0)
      and ((.provider|keys)-["identifier","version","mode"]|length==0)
      and ((keys - ["handle","provider","event","correlationId"])|length==0)
      and ((.event|keys)-["conversationId","turnId","occurrenceId","elicitationId"]|length==0)
    then . else error("Need actual provider/turn envelope and fresh UUIDv7s") end |
    if $kind=="permission" then
      .event.name="permission" | .event.toolName="Bash" | del(.event.elicitationId)
    elif $kind=="question-summary" or $kind=="close-question" then
      if (.event.elicitationId|type=="string" and length>0) then . else error("Need the same elicitationId for open/close") end |
      if $kind=="question-summary" then .event.name="elicitation" | .event.message="Use staging DB?"
      else .event.name="elicitationResult" end
    else error("Unknown hook kind") end
  ' <<< "$envelope"
}

context_input_main() {
  case "${1:---help}" in
    --help) context_input_help ;;
    --self-test) source "$CONTEXT_INPUT_DIR/pane-context-input-self-test.sh"; context_input_self_test ;;
    form|hook)
      [ "$#" -eq 3 ] && [ -f "$3" ] || { context_input_help >&2; return 2; }
      if [ "$1" = form ]; then context_form "$2" "$(cat "$3")"; else context_hook "$2" "$(cat "$3")"; fi ;;
    *) context_input_help >&2; return 2 ;;
  esac
}
if [ "${BASH_SOURCE[0]}" = "$0" ]; then context_input_main "$@"; fi
