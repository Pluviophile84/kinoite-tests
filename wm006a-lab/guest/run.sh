#!/usr/bin/env bash
# Usage (as root in the guest): run.sh <phase>   e.g. run.sh 02-isolation
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SUITE="${1#*-}"; export SUITE
source "$HERE/lib.sh"
source "$HERE/$1.sh"
exit 0
