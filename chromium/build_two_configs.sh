#!/bin/bash
set -euo pipefail

SRC_DIR=${SRC_DIR:-/extra/alexey/chromium/chromium/src}
CONFIG_DIR="$SRC_DIR/build/config/sanitizers"
BUILD_GN="$CONFIG_DIR/BUILD.gn"
ARGS_TEMPLATE=/home/alexey/tsan-experiments/chromium/args.gn/args.gn.tsan
CONFIGS=(tsan tsan-all-no-peeling)
BACKUP=$(mktemp /tmp/chromium-build-gn.XXXXXX)
BACKUP_READY=0
START_TS=$(date '+%F %T %z')
LOG_FILE=${LOG_FILE:-/tmp/build_two_configs_$(date '+%Y%m%d_%H%M%S').log}

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

log() {
  printf '[%s] %s\n' "$(date '+%F %T %z')" "$*"
}

restore_build_gn() {
  [[ "$BACKUP_READY" -eq 1 && -f "$BACKUP" ]] && cp "$BACKUP" "$BUILD_GN"
  rm -f "$BACKUP"
}

cleanup() {
  local status=$?
  local end_ts
  end_ts=$(date '+%F %T %z')

  trap - EXIT INT TERM
  restore_build_gn

  if [[ "$status" -eq 0 ]]; then
    log "Finished successfully"
  else
    log "Finished with status $status"
  fi
  log "Started at: $START_TS"
  log "Finished at: $end_ts"
  log "Log file: $LOG_FILE"

  exit "$status"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

log "Started build_two_configs.sh"
log "Source dir: $SRC_DIR"
log "Log file: $LOG_FILE"

for cmd in gn autoninja; do
  command -v "$cmd" >/dev/null || { echo "Missing command: $cmd" >&2; exit 1; }
done
for path in "$SRC_DIR" "$BUILD_GN" "$ARGS_TEMPLATE"; do
  [[ -e "$path" ]] || { echo "Missing path: $path" >&2; exit 1; }
done
for cfg in "${CONFIGS[@]}"; do
  [[ -f "$CONFIG_DIR/BUILD.gn.$cfg" ]] || { echo "Missing config: $CONFIG_DIR/BUILD.gn.$cfg" >&2; exit 1; }
done

cp "$BUILD_GN" "$BACKUP"
BACKUP_READY=1
cd "$SRC_DIR"

for cfg in "${CONFIGS[@]}"; do
  out="out/chrome-$cfg"
  log "==> Building $cfg in $out"
  mkdir -p "$out"
  cp "$ARGS_TEMPLATE" "$out/args.gn"
  cp "$CONFIG_DIR/BUILD.gn.$cfg" "$BUILD_GN"
  gn gen "$out"
  autoninja -C "$out" chrome
  log "Completed $cfg"
  echo
 done

log "Done: ${CONFIGS[*]}"


