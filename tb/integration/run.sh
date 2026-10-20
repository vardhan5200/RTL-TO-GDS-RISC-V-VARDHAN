#!/usr/bin/env bash
# Integrated-core tests (Icarus Verilog): soc_core_top program test with and
# without the MMU in the data path, a core-level Sv32 translation test and a
# core-level DIV/DIVU/REM/REMU test, a core-level MMU page-fault trap test and
# a satp CSR test (software enables / disables / re-roots the MMU) and an
# instruction-fetch translation / instruction page-fault test, fetch
# translation following the privilege mode, and SFENCE.VMA TLB flushes.
set -u
cd "$(dirname "$0")/../.."
OUT=${SIM_OUT:-/tmp/integration_sim}; mkdir -p "$OUT"
python3 tb/integration/gen_prog.py >/dev/null
CORE="rtl/cpu/decoder.sv rtl/cpu/imm_gen.sv rtl/cpu/alu.sv rtl/cpu/branch_unit.sv rtl/cpu/mul.sv
      rtl/cpu/div.sv rtl/cpu/div_unit.sv
      rtl/cache/dm_cache.sv rtl/cache/icache.sv rtl/priv/csr_file.sv rtl/priv/priv_unit.sv rtl/mmu/*.sv rtl/core/core_top.sv"
SOC="rtl/soc/soc_map_pkg.sv rtl/soc/addr_decode.sv rtl/soc/timer.sv rtl/soc/irq_ctrl.sv rtl/soc/uart.sv rtl/soc/soc_core_top.sv"
fail=0
run() { local name=$1 pat=$2; shift 2
  if ! iverilog -g2012 -o "$OUT/$name.vvp" "$@" 2>"$OUT/$name.log"; then
    grep -v "sorry:" "$OUT/$name.log"; echo "$name: COMPILE FAIL"; fail=1; return; fi
  local res; res=$(timeout 60 vvp -n "$OUT/$name.vvp")
  echo "$res" | grep -vE '\$finish'
  echo "$res" | grep -q "$pat" || fail=1
}
run core_int        "CORE INTEGRATION: PASS" -s core_int_tb $SOC $CORE tb/integration/core_int_tb.sv
run core_int_mmu    "CORE INTEGRATION: PASS" -s core_int_tb -P core_int_tb.USE_MMU=1 $SOC $CORE tb/integration/core_int_tb.sv
run core_mmu        "CORE MMU: PASS"         -s core_mmu_tb $CORE tb/integration/core_mmu_tb.sv
run core_div        "CORE DIV: PASS"         -s core_div_tb $CORE tb/integration/core_div_tb.sv
run core_pf         "CORE PAGE FAULT: PASS"  -s core_pf_tb $CORE tb/integration/core_pf_tb.sv
run core_satp       "CORE SATP: PASS"        -s core_satp_tb $CORE tb/integration/core_satp_tb.sv
run core_ifetch     "CORE IFETCH: PASS"      -s core_ifetch_tb $CORE tb/integration/core_ifetch_tb.sv
run core_fetch_priv "CORE FETCH PRIV: PASS"  -s core_fetch_priv_tb $CORE tb/integration/core_fetch_priv_tb.sv
run core_sfence     "CORE SFENCE: PASS"      -s core_sfence_tb $CORE tb/integration/core_sfence_tb.sv
[ $fail -eq 0 ] && echo "ALL INTEGRATION TESTS PASSED" || { echo "INTEGRATION TESTS FAILED"; exit 1; }
