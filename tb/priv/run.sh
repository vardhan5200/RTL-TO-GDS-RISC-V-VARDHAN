#!/usr/bin/env bash
# Run the privileged-architecture tests with Icarus Verilog.
#   priv_unit_tb      : M-mode CSRs / traps / interrupts / satp (unit level)
#   priv_modes_tb     : M/S/U privilege modes in priv_unit (unit level)
#   core_priv_mmu_tb  : privilege modes + Sv32 MMU in core_top (M bypass, S/U translate)
# Usage: tb/priv/run.sh
set -u
cd "$(dirname "$0")/../.."
OUT=${SIM_OUT:-/tmp/priv_sim}; mkdir -p "$OUT"
PRIV="rtl/cpu/decoder.sv rtl/priv/csr_file.sv rtl/priv/priv_unit.sv"
CORE="rtl/cpu/decoder.sv rtl/cpu/imm_gen.sv rtl/cpu/alu.sv rtl/cpu/branch_unit.sv rtl/cpu/mul.sv
      rtl/cpu/div.sv rtl/cpu/div_unit.sv rtl/cache/dm_cache.sv rtl/cache/icache.sv rtl/priv/csr_file.sv
      rtl/priv/priv_unit.sv rtl/mmu/*.sv rtl/core/core_top.sv"
fail=0
run() { local top=$1 pat=$2; shift 2
  if ! iverilog -g2012 -s "$top" -o "$OUT/$top.vvp" "$@" 2>"$OUT/$top.log"; then
    grep -v "sorry:" "$OUT/$top.log"; echo "PRIV $top: COMPILE FAIL"; fail=1; return; fi
  local res; res=$(timeout 60 vvp -n "$OUT/$top.vvp")
  echo "$res" | grep -vE '\$finish'
  echo "$res" | grep -q "$pat" || fail=1
}
run priv_unit_tb     "PRIV: PASSED"          $PRIV tb/priv/priv_unit_tb.sv
run priv_modes_tb    "PRIV MODES: PASSED"    $PRIV tb/priv/priv_modes_tb.sv
run core_priv_mmu_tb "CORE PRIV MMU: PASSED" $CORE tb/priv/core_priv_mmu_tb.sv
[ $fail -eq 0 ] && echo "PRIV SUITE: ALL PASSED" || { echo "PRIV SUITE: FAILED"; exit 1; }
