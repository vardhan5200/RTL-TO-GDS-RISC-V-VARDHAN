# RTL-to-GDS RISC-V (Vardhan)

Open-source RV32I processor development: architecture → RTL → verification → physical design (SkyWater 130 nm).

## Current status

| Component | Status | Notes |
|-----------|--------|-------|
| Architecture docs | Done | Phase 0 |
| ALU / imm_gen / decoder | Done | Full RV32I base |
| Single-cycle reference CPU | Done | Functional oracle |
| Minimal 5-stage pipeline | Done | Subset + forwarding |
| SoC (ROM, SRAM, UART, GPIO, timer) | Done | Working programs |
| **First GDS (SKY130)** | **Done** | `single_cycle_cpu` fully placed & routed |
| L1 caches | Partial | Control works; data path needs work |
| Modular pipeline CPI | Measured | See baselines below |

## Performance baselines (micro-benchmark)

| Design | Instructions | Cycles | CPI |
|--------|--------------|--------|-----|
| Single-cycle | 22 | 22 | **1.00** |
| Pipeline (simplified) | 22 | 39 | **≈1.77** |

These numbers are the checkpoint for future improvements (better pipeline, caches, etc.).

## Repository layout

```
docs/                  Phase 0 specifications
rtl/cpu/               Single-cycle CPU + building blocks
rtl/pipeline/          Pipeline experiments + pipeline_top.sv
rtl/cache/             Cache experiments
soc.sv / soc_min.sv / soc_timer.sv
bench.sv / bench_pipe.sv   CPI micro-benchmarks
```

## Quick simulation

```bash
# Single-cycle SoC
iverilog -g2012 -s soc -o sim/soc.vvp rtl/cpu/*.sv soc.sv && vvp sim/soc.vvp

# CPI baseline (single-cycle)
iverilog -g2012 -s bench -o sim/bench.vvp rtl/cpu/*.sv bench.sv && vvp sim/bench.vvp
```

## Physical design

OpenROAD Flow Scripts + SKY130HD was used to generate:

```
results/sky130hd/single_cycle_cpu/base/6_final.gds
```

## Tools

- OSS CAD Suite (Icarus, Yosys, GTKWave)
- OpenROAD Flow Scripts + SKY130 (Docker)
- KLayout

## Next steps

- Improve pipeline (branches, full forwarding) and re-measure CPI
- Working L1 caches
- Longer-term: privileged spec, MMU, Linux boot
