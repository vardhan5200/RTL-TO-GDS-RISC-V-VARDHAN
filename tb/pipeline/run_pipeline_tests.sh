#!/usr/bin/env bash
# Run the pipeline regression with Icarus Verilog. Usage: tb/pipeline/run_pipeline_tests.sh
set -u
cd "$(dirname "$0")/../.."
OUT=${SIM_OUT:-/tmp/pipeline_sim}; mkdir -p "$OUT"
CORE="rtl/cpu/decoder.sv rtl/cpu/imm_gen.sv rtl/cpu/alu.sv rtl/cpu/branch_unit.sv rtl/cpu/mul.sv"
pass=0; fail=0
run() { local top=$1; shift
  if ! iverilog -g2012 -s "$top" -o "$OUT/$top.vvp" "$@" 2>"$OUT/$top.log"; then
    echo "$top: COMPILE FAIL"; cat "$OUT/$top.log"; fail=$((fail+1)); return; fi
  local res; res=$(timeout 60 vvp -n "$OUT/$top.vvp" | grep -v "REG WRITE")
  echo "$res" | grep -E "PASS|FAIL|cycles|Cycles|x1="
  if echo "$res" | grep -qE "PASS(ED)?\b" && ! echo "$res" | grep -q "FAIL"; then pass=$((pass+1)); else fail=$((fail+1)); fi
}
run tb_branch_loop  $CORE rtl/pipeline/pipeline_branch.sv tb/pipeline/tb_branch_loop.sv
run tb_pipe_mul     $CORE rtl/pipeline/pipeline_branch.sv tb/pipeline/tb_pipe_mul.sv
run tb_phase2       rtl/pipeline/pipe_phase2.sv tb/tb_phase2.sv
run tb_pipe_m       rtl/cpu/mul.sv rtl/pipeline/pipe_m.sv tb/tb_pipe_m.sv
run pipeline_cpu_tb rtl/cpu/*.sv rtl/memory/simple_memory.sv rtl/pipeline/if_id.sv rtl/pipeline/id_ex.sv \
                    rtl/pipeline/ex_mem.sv rtl/pipeline/mem_wb.sv rtl/pipeline/forward_unit.sv \
                    rtl/pipeline/pipeline_cpu.sv tb/cpu/pipeline_cpu_tb.sv
run pipe_min        rtl/pipeline/pipe_min_working.sv
echo "SUMMARY: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
