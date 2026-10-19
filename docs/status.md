# Project status — checkpoint `ba15d11`

**Checkpoint commit:** `ba15d11` — "Checkpoint: CPI baselines, first GDS, working M units"
**Date:** 2026-10-19
**Method:** every "Works" item below was re-run with Icarus Verilog (`iverilog -g2012`) on a clean export of `ba15d11`. Items marked *(not re-checked)* come only from commit messages or the README.

## Works

| Item | Evidence (testbench → result) |
|------|-------------------------------|
| ALU, imm_gen, decoder (RV32I base) | `tb/unit/alu_tb.sv`, `imm_gen_tb.sv`, `decoder_tb.sv` → ALL TESTS PASSED |
| Single-cycle reference CPU | `tb/cpu/sc_full_tb.sv` → FULL SINGLE-CYCLE: PASSED |
| Minimal 5-stage pipeline (ADDI/ADD/SW/LW + forwarding) | `pipe_min.sv` (same as `rtl/pipeline/pipe_min_working.sv`) → STEP3d: FULL PROGRAM PASSED |
| Test SoCs on the single-cycle CPU | `soc.sv` → SOC: PASSED (UART 'H','i', GPIO 0x55, done flag); `soc_min.sv` → MIN SOC: PASSED; `soc_timer.sv` → SOC+TIMER: PASSED |
| Iterative multiply unit (standalone) | `rtl/cpu/mul.sv`, `tb/unit/mul_tb.sv` → MUL: PASSED (6*7=42) |
| Simple divide unit (standalone) | `rtl/cpu/div.sv`, `tb/unit/div_tb.sv` → DIV: PASSED (20/3 = 6 rem 2) |
| CPI baselines | `bench.sv` → 22 instr / 22 cycles = CPI 1.00; `bench_pipe.sv` → 39 cycles / 22 instr ≈ 1.77 |
| First GDS (SKY130HD, `single_cycle_cpu`) | *(not re-checked)* README and commit `f8f2392` say ORFS produced `results/sky130hd/single_cycle_cpu/base/6_final.gds`. That results directory is not in the repo. |

### Caveats on the numbers

- **Pipeline CPI ≈ 1.77 is approximate.** `bench_pipe.sv` does not wait for the program to finish. It runs `pipeline_top` for a fixed 40 clock edges (it counts 39) and divides by 22. `pipeline_top.sv` is a simplified ADDI/store-only model, not the modular `pipeline_cpu`.
- **Single-cycle CPI** comes from integer division (`cycles / 22`). The cycle count, 22, is exact.
- **The M units are minimal.** `mul` is a 32-cycle unsigned shift-and-add that returns the low 32 bits (MUL only, no MULH/MULHSU/MULHU). `div` does repeated subtraction with a 40-iteration safety cap. It handles only unsigned inputs with small quotients, has no divide-by-zero handling, and has no signed DIV/REM.

## Open / in progress

| Item | Current state at `ba15d11` |
|------|----------------------------|
| Pipeline branch / loop timing | `pipe_phase2.sv` + `tb/tb_phase2.sv` ends with `x1=9`, `x2=1` after 5 cycles. The 10-iteration loop does not run (commit `789c897`: "loop timing open"). `pipeline_branch.sv` + `bench_loop.sv` times out (x1=0, x2=0 after 101 cycles). |
| MUL connected into the pipeline | `rtl/pipeline/pipe_m.sv` + `tb/tb_pipe_m.sv` → PIPE+MUL: FAILED (x3=0, expected 42). Commit `2f55878`: "pipeline MUL connect still open". |
| L1 cache data path / refill | `tb/cache/dm_cache_tb.sv` returns `x` on the first miss and the hit that follows (expected 0), and 0 for word 1 (expected 1). The refill writes each beat into the wrong word. A candidate fix is on the unmerged local branch `fix/l1-cache-refill-data` (`f85fd93`) and is not part of this checkpoint. |
| Modular pipeline (`pipeline_cpu.sv` + stage registers) | `tb/cpu/pipeline_cpu_tb.sv` → PIPELINE: FAILED (all registers 0). The working pipeline is still the monolithic `pipe_min` model. |
| Cache integration | `dm_cache` is a standalone read-only direct-mapped cache (64 lines × 4 words) and is not connected to any CPU or SoC. There is no separate I/D cache, no write path, and no ready/valid memory interface yet. |
| Spec memory map | The `docs/memory_map.md` map (ROM 0x0000_0000, SRAM 0x1000_0000, peripherals 0x2000_xxxx) is not implemented. The test SoCs use small ad-hoc maps (see `docs/memory_map.md`). |
| Interrupts / interrupt controller | Not implemented. The timer in `soc_timer.sv` has COUNT and COMPARE only and raises no interrupt. No CSRs or trap logic exist. |
| Privileged / system instructions | The decoder accepts ECALL/EBREAK/FENCE as no-ops. There are no CSRs, traps, or `FENCE.I`. |
| Byte/halfword loads and stores | Decoded, but the single-cycle datapath uses `dmem_wstrb = 4'b1111` and does not sign-extend or select bytes on loads. Only word accesses work. |
| Physical design beyond `single_cycle_cpu` | Not started for the pipeline, caches, or SoC. |
