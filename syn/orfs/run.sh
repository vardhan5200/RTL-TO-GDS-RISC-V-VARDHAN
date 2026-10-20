#!/usr/bin/env bash
# Run inside an ORFS environment (source env.sh first):
#   ORFS=/OpenROAD-flow-scripts syn/orfs/run.sh <rtl_dir> <work_home>
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
ORFS=${ORFS:-/OpenROAD-flow-scripts}
RTL=$1; WH=$2
make -C "$ORFS/flow" DESIGN_CONFIG="$here/config.mk" RISCV_RTL="$RTL" WORK_HOME="$WH" synth floorplan place cts
make -C "$ORFS/flow" DESIGN_CONFIG="$here/config.mk" RISCV_RTL="$RTL" WORK_HOME="$WH" \
     RUN_SCRIPT="$here/ppa_report.tcl" PIPE_PATHS_TCL="$here/pipe_paths_orfs.tcl" PPA_STAGE=4_cts run
