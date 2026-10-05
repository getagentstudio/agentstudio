#!/bin/bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: /bin/bash scripts/benchmark-cli-latency.sh /absolute/private/fixture.json" >&2
  exit 2
fi
script_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec /usr/bin/perl "$script_root/benchmark-cli-latency.pl" "$1"
