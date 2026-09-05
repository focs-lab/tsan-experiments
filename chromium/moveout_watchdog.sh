#!/bin/bash
# moveout_watchdog.sh <hash> [cfgs] — while the Chromium builds run on the SSD scratch, relocate every finished
# out dir to /extra as soon as its build_info.txt appears (each build is ~48 GB and the SSD holds ~113 GB free).
# Also guards the free space: below 20 GB it SIGSTOPs the youngest ninja (resumable) instead of letting a build
# die on ENOSPC. Stops when every configuration is built and moved.
set -uo pipefail; cd "$(dirname "$0")"
HASH=${1:?}; CFGS=${2:-"tsan tsan-sound tsan-dom-ea-lo-st-swmr"}
SRC=/extra/alexey/chromium/chromium/src; SCRATCH=/home/alexey/tsan-experiments/.scratch
LOG=moveout_watchdog.log; stopped=""
log(){ echo "[$(date '+%F %T')] $*" >> "$LOG"; }
log "watchdog started for: $CFGS"
while :; do
  done_all=1
  for cfg in $CFGS; do
    out="$SRC/out/chrome-$cfg"; tgt=$(readlink -f "$out" 2>/dev/null)
    if [ -f "$out/build_info.txt" ] && grep -q "compiler_head: $HASH" "$out/build_info.txt" 2>/dev/null; then
      case "$tgt" in "$SCRATCH"/*) log "moving finished $cfg off the SSD ($(du -sh "$tgt" 2>/dev/null | cut -f1))"
        ./move_out.sh "$cfg" >> "$LOG" 2>&1 && log "moved $cfg; SSD free now $(df -BG --output=avail / | tail -1 | tr -d ' ')" ;; esac
    else done_all=0; fi
  done
  avail=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
  if [ "${avail:-999}" -lt 20 ] && [ -z "$stopped" ]; then
    young=$(ps -eo pid,etimes,comm --sort=etimes | awk '$3=="ninja"{print $1; exit}')
    [ -n "$young" ] && { kill -STOP "$young"; stopped="$young"; log "SSD below ${avail}G: SIGSTOPped ninja pid $young (resume with kill -CONT)"; }
  elif [ "${avail:-0}" -gt 60 ] && [ -n "$stopped" ]; then kill -CONT "$stopped" 2>/dev/null; log "SSD back to ${avail}G: resumed ninja $stopped"; stopped=""; fi
  [ $done_all = 1 ] && { log "all configurations built and relocated"; exit 0; }
  sleep 180
done
