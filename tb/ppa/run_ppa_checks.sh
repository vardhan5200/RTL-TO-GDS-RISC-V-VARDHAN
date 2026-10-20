#!/usr/bin/env bash
# PPA refactor checks (not part of `make test`):
#   1. formal equivalence (yosys miter + SAT) of rtl/cpu/alu.sv vs BASE's ALU
#   2. random MUL vectors (Icarus)
#   3. yosys generic synth cell/FF counts for alu, regfile, mul, div, div_unit
# Usage: tb/ppa/run_ppa_checks.sh [BASE_REF]   (default 53f6ec9 = integrate/core-v2)
set -u
cd "$(dirname "$0")/../.."
BASE=${1:-53f6ec9}; OUT=${SIM_OUT:-/tmp/ppa_checks}; mkdir -p "$OUT"
git show "$BASE:rtl/cpu/alu.sv" | sed 's/^module alu\b/module alu_old/' > "$OUT/alu_old.sv"
if yosys -q -p "read_verilog -sv $OUT/alu_old.sv rtl/cpu/alu.sv; proc; flatten; \
    miter -equiv -make_assert -flatten alu_old alu miter; hierarchy -top miter; \
    sat -verify -prove-asserts miter" >"$OUT/alu_equiv.log" 2>&1; then
  echo "ALU EQUIV: PASS (vs $BASE)"; else echo "ALU EQUIV: FAIL"; fi
iverilog -g2012 -s mul_rand_tb -o "$OUT/mul_rand.vvp" rtl/cpu/mul.sv tb/ppa/mul_rand_tb.sv && \
  vvp -n "$OUT/mul_rand.vvp" | grep "MUL_RAND"
for m in alu regfile mul div div_unit; do
  f="rtl/cpu/$m.sv"; [ $m = div_unit ] && f="rtl/cpu/div.sv rtl/cpu/div_unit.sv"
  yosys -q -p "read_verilog -sv $f; synth -flatten -top $m; tee -q -o $OUT/$m.stat stat" >/dev/null 2>&1
  printf "%-9s cells=%-6s FFs=%s\n" $m "$(awk '/Number of cells/{print $4}' $OUT/$m.stat)" \
    "$(awk '/DFF/{s+=$2} END{print s+0}' $OUT/$m.stat)"
done
