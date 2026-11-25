#!/usr/bin/env bash
# Usage (as root in the guest): run.sh <phase>   e.g. run.sh 02-isolation
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
PHASE="$1"; shift
SUITE="${SUITE:-${PHASE#*-}}"; export SUITE
source "$HERE/lib.sh"
source "$HERE/$PHASE.sh" "$@"
exit 0
