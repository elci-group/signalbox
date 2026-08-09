#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PREFIX=${HOME}/.local
WITH_DEPS=false
YES=false

usage() {
  cat <<'USAGE'
Usage: ./install.sh [--prefix PATH] [--deps] [--yes]

Installs Signalbox. --deps prints or, with --yes, runs the supported package plan.
USAGE
}

while (($#)); do
  case $1 in
    --prefix) [[ -n ${2:-} ]] || { echo '--prefix requires a value' >&2; exit 3; }; PREFIX=$2; shift 2 ;;
    --deps) WITH_DEPS=true; shift ;;
    --yes) YES=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 3 ;;
  esac
done

install_deps() {
  local missing=() tool
  for tool in jq shellcheck bats hyperfine; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
  done
  ((${#missing[@]})) || { echo 'Supported system dependencies are already present.'; return; }
  printf 'Dependency plan: sudo apt-get install -y %s\n' "${missing[*]}"
  $YES || { echo 'Re-run with --deps --yes to execute this plan.'; return 3; }
  command -v apt-get >/dev/null 2>&1 || { echo 'Automatic dependency installation supports apt-get only.' >&2; return 3; }
  sudo apt-get install -y "${missing[@]}"
}

$WITH_DEPS && install_deps

DATA_DIR=$PREFIX/share/signalbox
BIN_DIR=$PREFIX/bin
mkdir -p "$DATA_DIR" "$BIN_DIR"
rm -rf -- "${DATA_DIR:?}/bin" "${DATA_DIR:?}/lib" "${DATA_DIR:?}/config"
cp -a "$ROOT/bin" "$ROOT/lib" "$ROOT/config" "$DATA_DIR/"
ln -sfn "$DATA_DIR/bin/signalbox" "$BIN_DIR/signalbox"

if [[ -x $HOME/.local/libexec/bats-core/bats && $PREFIX == "$HOME/.local" ]]; then
  install -m 0755 "$ROOT/scripts/bats-relocatable" "$BIN_DIR/bats"
fi

if [[ $PREFIX == "$HOME/.local" ]]; then
  CREATOR=${SIGNALBOX_PLUGIN_CREATOR:-/home/sal/.codex/skills/.system/plugin-creator/scripts/create_basic_plugin.py}
  if [[ -f $CREATOR ]]; then
    python3 "$CREATOR" signalbox --path "$HOME/plugins" --with-skills --with-scripts --with-marketplace --force >/dev/null
    rm -rf -- "$HOME/plugins/signalbox/skills" "$HOME/plugins/signalbox/.codex-plugin"
    cp -a "$ROOT/skills" "$ROOT/.codex-plugin" "$HOME/plugins/signalbox/"
  else
    echo 'Plugin creator unavailable; CLI installed but plugin marketplace was not updated.' >&2
  fi
fi

SIGNALBOX_HOME=$DATA_DIR "$BIN_DIR/signalbox" doctor --json || true
printf 'Installed Signalbox %s to %s\n' "$(<"$ROOT/VERSION")" "$PREFIX"
