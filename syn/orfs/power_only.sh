#!/usr/bin/env bash
# power_only.sh <rtl_dir> <work_home> <vcd>
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
ORFS=${ORFS:-/OpenROAD-flow-scripts}
make -C "$ORFS/flow" DESIGN_CONFIG="$here/config.mk" FLOW_VARIANT="${FLOW_VARIANT:-base}" RISCV_RTL="$1" WORK_HOME="$2" \
     RUN_SCRIPT="$here/power_vcd.tcl" VCD="$3" run
