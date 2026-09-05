#!/bin/bash
cd "$(dirname "$0")"
P5_LOCK=/tmp/p5-smoke.lock exec ./run.sh memcached 729521af8965 1 --configs "orig tsan"
