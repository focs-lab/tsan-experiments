#!/bin/bash
# configs.sh — the configuration set of the performance re-measurement (P5) and per-app name mapping.
# Sourced by build.sh / run.sh. Names are the repo's (config_definitions.sh); Redis drops the "tsan-" prefix.
P5_STAGE_A="orig tsan tsan-sound tsan-dom-ea-lo-st-swmr tsan-dom_peeling-ea-lo-st-swmr tsan-dom_peeling-ea-lo-st-swmr-wp"
P5_STAGE_B_EXTRA="tsan-st tsan-stmt tsan-swmr tsan-lo tsan-ea tsan-dom tsan-dom_peeling tsan-sound-wp tsan-sound-tfn tsan-sound-tfn-wp"
P5_TFN_APPS="memcached"   # -tsan-thread-free-names rows; Redis dropped: its list changes 0 sites per unit and 0 beyond the WP summaries (both built on d3bf9f8c39fe)
P5_ALL="$P5_STAGE_A $P5_STAGE_B_EXTRA"
# apps whose build scripts consume whole-program summaries (the -wp rows exist only for these)
P5_WP_APPS="memcached redis sqlite"
# label for tables: AllOpt+peel = the paper's AllOpt; AllOpt-peel = dominance without loop peeling
p5_label() {
  case "$1" in
    tsan-dom-ea-lo-st-swmr) echo "AllOpt-peel";; tsan-dom_peeling-ea-lo-st-swmr) echo "AllOpt+peel";;
    tsan-dom_peeling-ea-lo-st-swmr-wp) echo "AllOpt+peel (WP summaries)";; tsan-sound-wp) echo "sound (WP summaries)";;
    *) echo "$1";;
  esac
}
# base config name (without -wp) and the build tag
p5_base() { echo "${1%-wp}"; }
p5_tag()  { case "$1" in *-wp) echo "-wp";; *) echo "";; esac; }
# Redis spells configs without the tsan- prefix ("orig" stays)
p5_redis_name() { local b; b=$(p5_base "$1"); echo "${b#tsan-}"; }
# does this app have a -wp row?
p5_has_wp() { case " $P5_WP_APPS " in *" $1 "*) return 0;; *) return 1;; esac; }
# configs for an app: drop -wp rows where unsupported
p5_configs_for() { local app=$1 set=$2 out=""; for c in $set; do case "$c" in *-tfn*) case " $P5_TFN_APPS " in *" $app "*) ;; *) continue;; esac;; esac; case "$c" in *-wp) p5_has_wp "$app" || continue;; esac; out="$out $c"; done; echo $out; }
