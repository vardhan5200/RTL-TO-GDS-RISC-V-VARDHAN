#!/usr/bin/env bash
# Full sky130hd run (synth, floorplan, place, CTS) + post-CTS PPA report.
# Run inside an ORFS environment (e.g. the openroad/orfs image, source env.sh first):
#   ORFS=/OpenROAD-flow-scripts syn/orfs/run.sh [rtl_dir] [work_home]
# Env: FLOW_VARIANT=base|mmu (default base, mmu = USE_MMU=1),
#      CLK_PERIOD_NS (default 10, see constraint.sdc), TARGETS (default "synth floorplan place cts").
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
ORFS=${ORFS:-/OpenROAD-flow-scripts}
RTL=${1:-$(cd "$here/../../rtl" && pwd)}; WH=${2:-/tmp/riscv_ppa}
V=${FLOW_VARIANT:-base}
make -C "$ORFS/flow" DESIGN_CONFIG="$here/config.mk" FLOW_VARIANT="$V" RISCV_RTL="$RTL" WORK_HOME="$WH" \
     ${TARGETS:-synth floorplan place cts}
make -C "$ORFS/flow" DESIGN_CONFIG="$here/config.mk" FLOW_VARIANT="$V" RISCV_RTL="$RTL" WORK_HOME="$WH" \
     RUN_SCRIPT="$here/ppa_report.tcl" PIPE_PATHS_TCL="$here/pipe_paths_orfs.tcl" PPA_STAGE=4_cts \
     RUN_LOG_NAME_STEM=ppa_report run
