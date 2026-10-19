#!/usr/bin/env bash
# Run the machine-mode privileged unit tests with Icarus Verilog.
# Usage: tb/priv/run.sh
set -eu
cd "$(dirname "$0")/../.."
OUT=${SIM_OUT:-/tmp/priv_sim}; mkdir -p "$OUT"
iverilog -g2012 -s priv_unit_tb -o "$OUT/priv_unit_tb.vvp" \
    rtl/cpu/decoder.sv rtl/priv/csr_file.sv rtl/priv/priv_unit.sv tb/priv/priv_unit_tb.sv
res=$(vvp -n "$OUT/priv_unit_tb.vvp")
echo "$res"
echo "$res" | grep -q "PRIV: PASSED"
