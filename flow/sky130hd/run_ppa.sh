#!/usr/bin/env bash
# Quick PPA run (synth + floorplan + place) with OpenROAD-flow-scripts.
# Run inside an ORFS environment (e.g. the openroad/orfs image, after `source env.sh`).
#   ORFS=/OpenROAD-flow-scripts flow/sky130hd/run_ppa.sh [base|mmu] [make targets...]
# base = core_top defaults (USE_MMU=0), mmu = core_top with USE_MMU=1.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
ORFS=${ORFS:-/OpenROAD-flow-scripts}
variant=${1:-base}; shift || true
targets=${*:-synth floorplan place}
WORK_HOME=${WORK_HOME:-/tmp/riscv_ppa}
# Synthesis-only copy of rtl/ with the async-reset/flush always_ff blocks split
# (see split_async_flush.py). rtl/ itself is not touched.
python3 "$here/split_async_flush.py" "$repo/rtl" "$WORK_HOME/synth_rtl"
make -C "$ORFS/flow" DESIGN_CONFIG="$here/config.mk" FLOW_VARIANT="$variant" \
     WORK_HOME="$WORK_HOME" RISCV_RTL="$WORK_HOME/synth_rtl" $targets
