# RTL-to-GDS RISC-V (Vardhan)

Open-source RV32I processor development: architecture → RTL → verification → physical design (SkyWater 130 nm).

## Current status

Checkpoint: commit `ba15d11` ("Checkpoint: CPI baselines, first GDS, working M units"). For details and evidence, see [`docs/status.md`](docs/status.md).

| Component | Status | Notes |
|-----------|--------|-------|
| Architecture docs | Done | Phase 0 specs (target design; not all implemented yet) |
| ALU / imm_gen / decoder | Done | Full RV32I base; unit tests pass |
| Single-cycle reference CPU | Done | Functional oracle; word loads/stores only |
| Minimal 5-stage pipeline | Done | `pipe_min.sv`: ADDI/ADD/SW/LW + forwarding |
| Test SoCs (single-cycle CPU) | Done | `soc.sv` (ROM, SRAM, UART, GPIO, done flag), `soc_min.sv`, `soc_timer.sv` (timer) |
| **First GDS (SKY130)** | **Done** | `single_cycle_cpu` placed & routed with ORFS (results not committed) |
| **M extension units** | **Done (standalone)** | `mul.sv` (6*7=42), `div.sv` (20/3=6 rem 2); minimal, unsigned |
| CPI baselines | Measured | Single-cycle 1.00, pipeline ≈1.77 (see below) |
| Pipeline branches / loop timing | **In progress** | `pipe_phase2` / `pipeline_branch` loop tests do not complete yet |
| MUL connected into pipeline | **In progress** | `tb_pipe_m` fails (x3=0, expected 42) |
| L1 cache data path | **In progress** | Refill writes the wrong words; `dm_cache_tb` returns wrong data |
| Modular pipeline (`pipeline_cpu.sv`) | In progress | `pipeline_cpu_tb` fails |
| Interrupts, CSRs, spec memory map | Not started | |

## Performance baselines (micro-benchmark)

| Design | Instructions | Cycles | CPI |
|--------|--------------|--------|-----|
| Single-cycle | 22 | 22 | **1.00** |
| Pipeline (simplified) | 22 | 39 | **≈1.77** |

These numbers are the baseline for future improvements (better pipeline, caches, etc.).
The pipeline figure is approximate. `bench_pipe.sv` runs the simplified `pipeline_top` for a fixed 40 cycles and divides by 22; it does not detect program completion.

## Repository layout

```
docs/                  Phase 0 specifications + status.md
rtl/cpu/               Single-cycle CPU, building blocks, mul.sv, div.sv
rtl/memory/            simple_memory.sv (testbench data memory)
rtl/pipeline/          Pipeline experiments (pipe_min_working, pipeline_top,
                       pipeline_branch, pipe_phase2, pipe_m, modular pipeline_cpu)
rtl/cache/             dm_cache.sv (standalone direct-mapped cache)
tb/unit/ tb/cpu/ tb/cache/ tb/tb_phase2.sv tb/tb_pipe_m.sv   Testbenches
soc.sv / soc_min.sv / soc_timer.sv   Test SoCs (single-cycle CPU)
pipe_min.sv            Self-contained 5-stage pipeline test
bench.sv / bench_pipe.sv / bench_loop.sv   CPI / loop micro-benchmarks
sim/                   Compiled Icarus .vvp outputs
```

## Quick simulation

```bash
# Single-cycle SoC
iverilog -g2012 -s soc -o sim/soc.vvp rtl/cpu/*.sv soc.sv && vvp sim/soc.vvp

# CPI baseline (single-cycle)
iverilog -g2012 -s bench -o sim/bench.vvp rtl/cpu/*.sv bench.sv && vvp sim/bench.vvp

# CPI baseline (simplified pipeline)
iverilog -g2012 -s bench_pipe -o sim/bench_pipe.vvp rtl/pipeline/pipeline_top.sv bench_pipe.sv && vvp sim/bench_pipe.vvp

# M units (standalone)
iverilog -g2012 -o sim/mul.vvp rtl/cpu/mul.sv tb/unit/mul_tb.sv && vvp sim/mul.vvp
iverilog -g2012 -o sim/div.vvp rtl/cpu/div.sv tb/unit/div_tb.sv && vvp sim/div.vvp

# Minimal 5-stage pipeline
iverilog -g2012 -o sim/pipe_min.vvp pipe_min.sv && vvp sim/pipe_min.vvp
```

## Physical design

OpenROAD Flow Scripts + SKY130HD was used to generate:

```
results/sky130hd/single_cycle_cpu/base/6_final.gds
```

(ORFS output; it is not committed to this repository.)

## Tools

- OSS CAD Suite (Icarus, Yosys, GTKWave)
- OpenROAD Flow Scripts + SKY130 (Docker)
- KLayout

## Next steps

- Fix pipeline branch/loop timing (`pipe_phase2`, `pipeline_branch`), then re-measure CPI with a completion-detecting benchmark
- Connect the MUL/DIV units into the pipeline (`pipe_m`) with a stall
- Fix the L1 cache refill data path, then integrate I/D caches
- Get the modular `pipeline_cpu` to pass `pipeline_cpu_tb`
- Interrupts (timer interrupt, CSRs), then the spec memory map
- Longer-term: privileged spec, MMU, Linux boot
