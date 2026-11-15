#!/bin/bash
# Literal request checks. No app, storage, network or elapsed-time wait.
context_input_self_test() (
  set -euo pipefail
  local_input='{"handle":"self","messageId":"018f0000-0000-7000-8000-000000000001","writer":{"provider":"codex","conversationId":"owned-session"},"correlationId":"018f0000-0000-7000-8000-000000000002"}'
  hook_input='{"handle":"self","provider":{"identifier":"codex","version":"fixture","mode":"interactive"},"correlationId":"018f0000-0000-7000-8000-000000000002","event":{"conversationId":"owned-session","turnId":"owned-turn","occurrenceId":"018f0000-0000-7000-8000-000000000003","elicitationId":"owned-question"}}'
  passed=0
  context_form single "$local_input" | jq -e '.body=="Pick a color for the test?" and .shape.form=={kind:"choice",options:[{id:"red",label:"red"},{id:"blue",label:"blue"}],allowsMultiple:false} and .writer.conversationId=="owned-session"' >/dev/null; passed=$((passed+1))
  context_form multiple "$local_input" | jq -e '.shape.form.allowsMultiple==true and [.shape.form.options[].id]==["swift","bridge","e2e"]' >/dev/null; passed=$((passed+1))
  context_form freeText "$local_input" | jq -e '.shape.form=={kind:"freeText",placeholder:"Reply"}' >/dev/null; passed=$((passed+1))
  context_form elicitation "$local_input" | jq -e '.shape.form.schema.required==["environment","dryRun"] and .shape.form.schema.properties[1].type.kind=="boolean"' >/dev/null; passed=$((passed+1))
  context_form approval "$local_input" | jq -e '.shape.reason=="approval" and .shape.form=={kind:"approval"} and .shape.waiting=={kind:"nonBlocking"}' >/dev/null; passed=$((passed+1))
  context_hook permission "$hook_input" | jq -e '.event.name=="permission" and (.event|has("message")|not) and (.event|has("elicitationId")|not)' >/dev/null; passed=$((passed+1))
  context_hook question-summary "$hook_input" | jq -e '.event.name=="elicitation" and .event.message=="Use staging DB?" and .event.elicitationId=="owned-question"' >/dev/null; passed=$((passed+1))
  context_hook close-question "$hook_input" | jq -e '.event.name=="elicitationResult" and .event.elicitationId=="owned-question" and (.event|has("message")|not)' >/dev/null; passed=$((passed+1))
  if context_form approval "$(jq '.messageId="bad"' <<< "$local_input")" >/dev/null 2>&1; then exit 1; fi; passed=$((passed+1))
  if context_form invalid "$local_input" >/dev/null 2>&1; then exit 1; fi; passed=$((passed+1))
  if context_hook question-summary "$(jq 'del(.event.elicitationId)' <<< "$hook_input")" >/dev/null 2>&1; then exit 1; fi; passed=$((passed+1))
  if context_hook permission "$(jq '.event.message="invented approval summary"' <<< "$hook_input")" >/dev/null 2>&1; then exit 1; fi; passed=$((passed+1))
  if context_form single "$(jq '.credential="must-not-echo"' <<< "$local_input")" >/dev/null 2>&1; then exit 1; fi; passed=$((passed+1))
  if context_form single "$(jq '.handle="other-pane"' <<< "$local_input")" >/dev/null 2>&1; then exit 1; fi; passed=$((passed+1))
  if context_hook permission "$(jq '.handle="other-pane"' <<< "$hook_input")" >/dev/null 2>&1; then exit 1; fi; passed=$((passed+1))
  printf '%s passed, 0 failed; literal synthetic request checks only, no live proof\n' "$passed"
)
