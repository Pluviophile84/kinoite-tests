#!/usr/bin/env bash
# Usage: run-suite.sh 01-baseline   (runs tests/suites/01-baseline.sh as user "tester")
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
sudo mkdir -p /var/tmp/kinoite-tests && sudo chown tester: /var/tmp/kinoite-tests
SUITE="${1#*-}"
export SUITE
source "$HERE/lib.sh"
source "$HERE/suites/$1.sh"
exit 0
