#!/usr/bin/env bash
# tb/perf/run_perf.sh — build (Icarus, iverilog -g2012) and run the SoC
# microbenchmarks. Uses the committed sw/perf/perf.hex; no RISC-V toolchain
# needed. Rebuild the program with `make -C sw/perf` (riscv64-unknown-elf-gcc).
# Output: every PERF line plus "PERF SUITE: PASS|FAIL"; exit status 0 on PASS.
# Full log: $SIM_OUT/perf/perf_tb.log
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT="${SIM_OUT:-/tmp/riscv_sim}/perf"
mkdir -p "$OUT"
iverilog -g2012 -s perf_tb -o "$OUT/perf_tb.vvp" \
    rtl/soc/soc_map_pkg.sv rtl/soc/addr_decode.sv rtl/soc/uart.sv rtl/soc/timer.sv rtl/soc/irq_ctrl.sv \
    rtl/cpu/decoder.sv rtl/cpu/imm_gen.sv rtl/cpu/alu.sv rtl/cpu/branch_unit.sv rtl/cpu/mul.sv \
    rtl/cpu/div.sv rtl/cpu/div_unit.sv rtl/cache/dm_cache.sv rtl/cache/icache.sv \
    rtl/priv/csr_file.sv rtl/priv/priv_unit.sv rtl/mmu/*.sv rtl/core/core_top.sv \
    rtl/soc/soc_core_top.sv tb/perf/perf_tb.sv
vvp -n "$OUT/perf_tb.vvp" "$@" | tee "$OUT/perf_tb.log" | grep -E "^PERF|^  (ok|FAIL|TIMEOUT)|^CHECK|^perf_tb"
grep -q "^PERF SUITE: PASS" "$OUT/perf_tb.log"
