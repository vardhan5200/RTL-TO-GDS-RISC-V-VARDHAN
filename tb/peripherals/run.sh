#!/usr/bin/env bash
# Demo SoC tests (Icarus Verilog, iverilog -g2012 + vvp):
#   seven_seg_tb  - 7-segment driver unit test
#   matmul4x4_tb  - 4x4 matmul accelerator vs TB reference (random + corners)
#   demo_soc_tb   - sw/demo/demo.hex on rtl/peripherals/demo_soc.sv: 7-seg
#                   count, matmul over UART, UART command shell
# The firmware hex is committed; rebuild with `make -C sw/demo`.
# Prints the full demo transcript; exits non-zero if any test fails.
set -u
cd "$(dirname "$0")/../.."
OUT=${SIM_OUT:-sim}; mkdir -p "$OUT"
CORE="rtl/cpu/decoder.sv rtl/cpu/imm_gen.sv rtl/cpu/alu.sv rtl/cpu/branch_unit.sv rtl/cpu/mul.sv
      rtl/cpu/div.sv rtl/cpu/div_unit.sv
      rtl/cache/dm_cache.sv rtl/cache/icache.sv rtl/priv/csr_file.sv rtl/priv/priv_unit.sv rtl/mmu/*.sv rtl/core/core_top.sv"
SOC="rtl/soc/soc_map_pkg.sv rtl/soc/addr_decode.sv rtl/soc/uart.sv"
PER="rtl/peripherals/seven_seg.sv rtl/peripherals/matmul4x4.sv rtl/peripherals/demo_soc.sv"
fail=0
run() { local name=$1 pat=$2; shift 2
  if ! iverilog -g2012 -o "$OUT/$name.vvp" "$@" 2>"$OUT/$name.log"; then
    grep -v "sorry:" "$OUT/$name.log"; echo "$name: COMPILE FAIL"; fail=1; return; fi
  local res; res=$(timeout 300 vvp -n "$OUT/$name.vvp" | grep -vE '\$finish|^REG WRITE')
  echo "$res"
  echo "$res" | grep -q "$pat" || fail=1
}
run seven_seg "SEVEN_SEG TEST: PASS" -s seven_seg_tb rtl/peripherals/seven_seg.sv tb/peripherals/seven_seg_tb.sv
run matmul4x4 "MATMUL4X4 TEST: PASS" -s matmul4x4_tb rtl/peripherals/matmul4x4.sv tb/peripherals/matmul4x4_tb.sv
run demo_soc  "DEMO SOC TEST: PASS"  -s demo_soc_tb $SOC $PER $CORE tb/peripherals/demo_soc_tb.sv
[ $fail -eq 0 ] && echo "ALL DEMO TESTS PASSED" || { echo "DEMO TESTS FAILED"; exit 1; }
