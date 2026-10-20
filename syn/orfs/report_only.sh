#!/usr/bin/env bash
# Re-run only the PPA report on an existing ORFS run: report_only.sh <rtl_dir> <work_home>
# (FLOW_VARIANT / CLK_PERIOD_NS as for run.sh)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
ORFS=${ORFS:-/OpenROAD-flow-scripts}
make -C "$ORFS/flow" DESIGN_CONFIG="$here/config.mk" FLOW_VARIANT="${FLOW_VARIANT:-base}" RISCV_RTL="$1" WORK_HOME="$2" \
     RUN_SCRIPT="$here/ppa_report.tcl" PIPE_PATHS_TCL="$here/pipe_paths_orfs.tcl" PPA_STAGE=4_cts \
     RUN_LOG_NAME_STEM=ppa_report run
