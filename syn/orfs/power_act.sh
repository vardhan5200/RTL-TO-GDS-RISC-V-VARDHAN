#!/usr/bin/env bash
# power_act.sh <rtl_dir> <work_home> <activity.tcl>
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
ORFS=${ORFS:-/OpenROAD-flow-scripts}
make -C "$ORFS/flow" DESIGN_CONFIG="$here/config.mk" FLOW_VARIANT="${FLOW_VARIANT:-base}" RISCV_RTL="$1" WORK_HOME="$2" \
     RUN_SCRIPT="$here/apply_activity.tcl" ACT_TCL="$3" run
