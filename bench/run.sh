#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SIGNALBOX_HOME=$ROOT "$ROOT/bin/signalbox" benchmark "$@"
