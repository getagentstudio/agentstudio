#!/usr/bin/env bash
set -euo pipefail
script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
repository_root="$(cd -- "${script_directory}/../../.." && pwd -P)"
lab_root="${AS_AGENT_DESKTOP_LAB:-${repository_root}/tmp/test-labs/2026-11-01-agent-desktop-vm}"
export TART_HOME="${lab_root}/tart-home"
export TART_NO_AUTO_PRUNE=1
tart_binary="${lab_root}/tools/tart/tart.app/Contents/MacOS/tart"
vm_name="${AS_AGENT_DESKTOP_VM:-agentstudio-ax-worker-1}"
command_name="${1:-status}"
shift || true
case "${command_name}" in
  status)
    "${tart_binary}" --version
    "${lab_root}/tools/agent-desktop/agent-desktop" version
    exec "${tart_binary}" list --format json
    ;;
  configure)
    exec "${tart_binary}" set "${vm_name}" --cpu 4 --memory 8192 --display 1280x800 --no-display-refit
    ;;
  start)
    exec "${tart_binary}" run --no-graphics --no-clipboard --no-audio --no-usb-accessories --vnc-experimental "${vm_name}"
    ;;
  stop) exec "${tart_binary}" stop "${vm_name}" ;;
  clone)
    if [[ "$#" -ne 1 ]]; then echo "Usage: lab.sh clone NEW_WORKER_NAME" >&2; exit 2; fi
    exec "${tart_binary}" clone agentstudio-ax-golden "$1"
    ;;
  guest) exec "${tart_binary}" exec "${vm_name}" "$@" ;;
  *) echo "Usage: lab.sh status|configure|start|stop|clone NAME|guest COMMAND..." >&2; exit 2 ;;
esac
