#!/bin/bash
# ccd0_who.sh (6 Oct 13:5x): when apollo's CCD0 (0-7,32-39) averages >= 0.10 busy over 5 s, log who runs there
# (pid, user, cpu, %cpu, age, command) to ~/p5-apollo/ccd0_who.log, at most one snapshot per 30 s. Light: one /proc/stat read per 5 s.
L=$HOME/p5-apollo/ccd0_who.log; C="0 1 2 3 4 5 6 7 32 33 34 35 36 37 38 39"; last=0
snap() { awk -v c=" $C " '$1 ~ /^cpu[0-9]+$/ { n=substr($1,4); if (index(c, " " n " ")) { b+=$2+$3+$4+$7+$8; t+=$2+$3+$4+$5+$6+$7+$8 } } END { print b, t }' /proc/stat; }
read b0 t0 < <(snap)
while :; do sleep 5; read b1 t1 < <(snap); u=$(awk -v b=$((b1-b0)) -v t=$((t1-t0)) 'BEGIN{ printf "%.3f", (t>0 ? b/t : 0) }'); b0=$b1; t0=$t1
  now=$(date +%s); if awk -v u=$u 'BEGIN{exit !(u>=0.10)}' && [ $((now-last)) -ge 30 ]; then last=$now
    { echo "[$(date '+%F %T')] CCD0 busy $u; top processes on CCD0:"; ps -eo pid,user,psr,pcpu,etimes,args --sort=-pcpu | awk -v c=" $C " 'NR==1 || index(c, " " $3 " ")' | head -12 | cut -c1-200; } >> $L
  fi; done
