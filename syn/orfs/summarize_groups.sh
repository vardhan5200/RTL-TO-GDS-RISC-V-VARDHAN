#!/usr/bin/env bash
# summarize_groups.sh <report log>: worst path per GROUP (arrival incl. clock latency, slack)
awk '/^GROUP/{g=$2; s=""; e=""} /^Startpoint:/{s=$2} /^Endpoint:/{e=$2} /data arrival time/{arr=$1} /slack \(/{ if (g!="" && !done[g]++) printf "%-10s arrival=%7s slack=%7s  %s -> %s\n", g, arr, $1, s, e }' "$1"
