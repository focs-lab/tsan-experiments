#!/bin/bash
# bench_session.sh — run ./run.sh inside a `bench` reservation (used only when someone else already holds one).
# Usage: ./bench_session.sh <app> <hash> [N] [--configs "..."]
set -uo pipefail
cd "$(dirname "$0")"; source ./lib.sh
APP=${1:?}; HASH=${2:?}; shift 2
case "$APP" in ffmpeg|chromium) CPUS=16; MEM=64G;; *) CPUS=48; MEM=96G;; esac
S="p5-$APP-$$"
p5_log "opening bench reservation -c $CPUS -m $MEM in tmux session $S"
tmux new-session -d -s "$S" "bench -c $CPUS -m $MEM"
sleep 5
tmux send-keys -t "$S" "cd $P5_DIR && ./run.sh $APP $HASH $* --in-bench --cpuset \$(cat /sys/fs/cgroup/\$(cat /proc/self/cgroup | cut -d: -f3)/cpuset.cpus.effective 2>/dev/null || nproc >/dev/null; echo 0-\$((\$(nproc)-1))); exit" Enter
while tmux has-session -t "$S" 2>/dev/null; do sleep 60; done
p5_log "bench session $S ended"
