#!/usr/bin/env bash
# summarize.sh <pipe_paths.log>: one line per group: arrival, slack, start -> end
awk '/^GROUP/{g=$2} /^Startpoint:/{s=$2} /^Endpoint:/{e=$2} /data arrival time/ && !a[g]++ {arr=$1} /slack/{if(!done[g]++) printf "%-16s arrival=%7s slack=%8s  %s -> %s\n", g, arr, $1, s, e}' "$1"
