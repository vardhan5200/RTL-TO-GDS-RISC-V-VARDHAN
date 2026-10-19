# RTL-to-GDS RISC-V (Vardhan)

Open-source RV32I processor development: architecture → RTL → verification → physical design (SkyWater 130 nm).

## Current Goal

A single-core core capable of running a minimal nginx-style benchmark (tiny bare-metal HTTP server or equivalent request-loop microbenchmark). Full nginx/Linux is out of scope; a measurable request-per-second style workload on the core is the target.

**Already working (integrated on `integrate/core-v1`):** 5-stage pipeline with MUL, L1 D-cache, basic M-mode privileged support (CSRs/traps), and a simple SoC.

**Remaining gaps:** DIV in the pipeline, I-cache, page-fault traps, and `satp` (MMU enable/translation control).

> **Note on the Current Goal section (checked against `integrate/core-v1` @ `aa8cbde`):** the integrated core, `rtl/core/core_top.sv`, is a **3-stage** pipeline (IF / ID / EX+MEM+WB), not 5-stage. The 5-stage designs (`pipe_min`, `pipeline_cpu`) are standalone test models. DIV in the pipeline, page-fault traps, `satp` and the I-cache all exist and pass their tests, but only on branches that are **not merged** into `integrate/core-v1` yet (see below).

## Current status (`integrate/core-v1` @ `aa8cbde`)

Every "Yes" row was verified by running `make test` on this commit; all suites pass. "Unmerged branch" rows were verified by running `make test` on that branch.

| Feature | In `integrate/core-v1`? | Evidence / notes |
|---------|-------------------------|------------------|
| RV32I ALU / imm_gen / decoder | Yes | `make test-unit`: ALU, DECODER, IMM_GEN all pass |
| Single-cycle reference CPU | Yes | `sc_full_tb`: FULL SINGLE-CYCLE: PASSED |
| Integrated pipelined core (`core_top`) | Yes, 3-stage | IF / ID / EX+MEM+WB, EX→ID bypass, branch/jump flush in EX. `make test-integration`: CORE INTEGRATION: PASS |
| Standalone pipeline models | Yes | `make test-pipeline`: 6/6 pass (branch loop CPI 1.909, PIPE+MUL, phase2 loop, modular 5-stage `pipeline_cpu`, `pipe_min`) |
| MUL in the pipeline | Yes, MUL only | Iterative 32-cycle `mul.sv`; the core stalls EX until it finishes. Integration test: 6*7=42 plus RAW use. MULH/MULHSU/MULHU are not decoded (they trap as illegal) |
| DIV/DIVU/REM/REMU in the pipeline | **No**, on unmerged `feat/pipeline-div` | On core-v1, DIV traps as illegal instruction (integration test checks "div not written", mcause 2). `feat/pipeline-div` (`6d9c1ad`) adds a restoring divider and wires it in; CORE DIV: PASS there |
| L1 D-cache | Yes | `dm_cache.sv`: direct-mapped, 64 lines × 16 B, blocking 4-beat refill, caches loads in 0x000–0x1FF. Stores are write-through and update the cached word on a hit (no write-allocate). `make test-cache`: 25/25. Integration: 1 miss + 3 hits |
| L1 I-cache | **No**, on unmerged `feat/icache` | core-v1 fetches combinationally from `imem`. `feat/icache` (`b76227e`) adds an 8-line direct-mapped I-cache; its icache / core_icache tests pass there |
| M-mode CSRs, traps, interrupts | Yes | `csr_file.sv` + `priv_unit.sv`: mstatus/misa/mie/mip/mtvec/mepc/mcause/mtval/mscratch, counters, ECALL/EBREAK/illegal/MRET, MEI/MSI/MTI with direct or vectored mtvec. `make test-priv`: 69/69. Integration: ECALL+MRET, external IRQ (mcause 0x8000000b) |
| Privilege modes S/U | **No** | M-mode only (`mstatus.MPP` hardwired to 11). No branch pushed to origin implements S/U mode |
| Sv32 MMU (TLB + page-table walker) | Partial | `rtl/mmu/` with a 4-entry TLB. `make test-mmu`: 34/34. In the core it sits on the **data side only** with `USE_MMU=1`; there is no instruction-side translation. CORE MMU: PASS |
| `satp` CSR | **No**, on unmerged `feat/satp` | On core-v1, `satp` and `priv_mode` are core input ports, tied to 0 / M in `soc_core_top`, so the MMU is a passthrough there. `feat/satp` (`0e56a14`) adds CSR 0x180 with a TLB flush on write; CORE SATP: PASS there |
| Page-fault traps | **No**, on unmerged `feat/mmu-page-fault` | On core-v1 an MMU fault squashes the access and sets the sticky `mmu_fault` output; no trap is taken. `feat/mmu-page-fault` (`2fd6557`) raises precise mcause 13/15 with mtval=VA; CORE PAGE FAULT: PASS there |
| SoC: ROM, SRAM, UART, GPIO, DONE, timer, IRQ controller | Yes | `rtl/soc/` with a central `addr_decode` and `soc_map_pkg`. `make test-soc`: IRQ CTRL / TIMER IRQ / SOC TOP pass. `soc_core_top` connects irq_ctrl to the core's `meip` |
| CPI baselines | Measured (older) | Single-cycle 1.00; simplified `pipeline_top` ≈1.77 over a fixed 40-cycle run (see below) |
| First GDS (SKY130HD, `single_cycle_cpu`) | Claimed, not reproducible from repo | Mentioned in commit `f8f2392`. The ORFS results and flow config are not committed. The pipelined core has not been through physical design |

**Branch stack (not merged):** `feat/pipeline-div` → `feat/mmu-page-fault` → `feat/satp`. `feat/icache` builds on `feat/mmu-page-fault`, not on `feat/satp`. Each branch is 1 commit behind `integrate/core-v1` (the README commit `aa8cbde`). `origin/main` is still at the older checkpoint `ba15d11`.

## Performance baselines (micro-benchmark)

| Design | Instructions | Cycles | CPI |
|--------|--------------|--------|-----|
| Single-cycle | 22 | 22 | **1.00** |
| Pipeline (simplified) | 22 | 39 | **≈1.77** |

These numbers predate the integrated core and were taken at `ba15d11`. The pipeline figure comes from `bench_pipe.sv`, which runs the simplified `pipeline_top` for a fixed 40 cycles and divides by 22 instructions; it does not detect program completion. `tb/pipeline/tb_branch_loop.sv` reports CPI 1.909 for a 10-iteration branch loop on `pipeline_branch`. `core_top` has not been benchmarked yet.

## Repository layout

```
ARCHITECTURE.md        Short as-built block overview
docs/                  Phase 0 specifications; memory_map.md has the as-built SoC map
rtl/core/core_top.sv   Integrated core: pipeline + D-cache + M-mode priv unit + optional Sv32 MMU
rtl/cpu/               Single-cycle CPU, ALU, decoder, imm_gen, regfile, branch unit, mul, div
rtl/pipeline/          Standalone pipeline models (pipeline_branch, pipe_min_working, pipeline_cpu, ...)
rtl/cache/dm_cache.sv  Direct-mapped L1 cache (used as the D-cache)
rtl/priv/              csr_file.sv, priv_unit.sv (M-mode CSRs and traps)
rtl/mmu/               Sv32 MMU: TLB, page-table walker, permission check
rtl/soc/               soc_map_pkg, addr_decode, timer, irq_ctrl, soc_top (single-cycle), soc_core_top (core_top)
tb/                    unit/, cpu/, pipeline/, cache/, priv/, mmu/, soc/, integration/
Makefile               Regression entry points (make test)
soc*.sv, bench*.sv, pipe_min.sv   Older top-level test SoCs and micro-benchmarks
```

## How to run tests

Requirements: Icarus Verilog (`iverilog -g2012`, `vvp`), `bash`, and `python3`. The integration suite runs `tb/integration/gen_prog.py`. Run from the repo root:

```bash
make test               # all suites; ends with "== make test: all suites passed"
make test-unit          # ALU, decoders, imm_gen, mul, div, single-cycle CPU, legacy SoCs
make test-pipeline      # standalone pipeline models (6 tests)
make test-cache         # dm_cache refill test (25 checks)
make test-priv          # M-mode CSR / trap unit (69 checks)
make test-mmu           # Sv32 MMU (34 tests)
make test-soc           # irq_ctrl, timer IRQ, soc_top
make test-integration   # soc_core_top with USE_MMU=0 and 1, core-level Sv32 test
```

Simulator outputs go to `$SIM_OUT` (default `/tmp/riscv_sim`). Exceptions: `tb/soc/run.sh` writes `.vvp` files into `sim/`, which dirties tracked files, and `tb/integration/run.sh` rewrites `tb/integration/*.hex` (with identical content at `aa8cbde`). To keep a checkout clean, run the tests in a scratch copy:

```bash
mkdir /tmp/rv && git archive HEAD | tar x -C /tmp/rv && make -C /tmp/rv test SIM_OUT=/tmp/rv/out
```

Single quick runs:

```bash
iverilog -g2012 -s soc -o /tmp/soc.vvp rtl/cpu/*.sv soc.sv && vvp -n /tmp/soc.vvp
iverilog -g2012 -s bench -o /tmp/bench.vvp rtl/cpu/*.sv bench.sv && vvp -n /tmp/bench.vvp
```

## Known limitations

- **3-stage integrated pipeline.** EX also does memory access and writeback. The only bypass is EX→ID. MUL and every load or store stall the whole pipeline, and there is no branch prediction (taken branches flush in EX).
- **M extension is incomplete in the core.** Only `MUL` is supported. MULH/MULHSU/MULHU trap as illegal, and so do DIV/DIVU/REM/REMU until `feat/pipeline-div` is merged.
- **No I-cache and no instruction-side MMU.** Instructions come from a combinational ROM port (`feat/icache` is not merged).
- **MMU is a data-side skeleton.** It has no ASID, no hardware A/D update, no PMP, no MPRV, and SUM/MXR are tied to 0. Only flush-all is supported, and in core-v1 nothing drives the flush. `satp` and privilege come from ports tied to Bare / M in `soc_core_top`, and faults do not trap (they only raise `mmu_fault`). The satp CSR and page-fault traps are on unmerged branches.
- **M-mode only.** No S/U modes, no `sret`, no delegation (`medeleg`/`mideleg`). WFI is a NOP.
- **D-cache:** one blocking miss at a time, no write-allocate, cacheable range fixed to 0x000–0x1FF (ROM + SRAM). There is no ready/valid memory arbiter: refill, PTW and uncached accesses share one combinational-read bus and are serialized by stalls.
- **Tiny SoC.** 256 B ROM, 256 B SRAM, and every register in the low 4 KiB. The timer reaches the core only through irq_ctrl → `meip` (`mtip`/`msip` are tied to 0 in `soc_core_top`). The UART is TX-only with no status register.
- **Unmapped accesses** set a sticky `bus_err` but raise no access-fault trap.
- **Physical design:** only an older `single_cycle_cpu` GDS is reported, and its ORFS results and config are not in the repo. No timing or area data exists for `core_top`.
- **No benchmark on `core_top` yet**, so there are no CPI or request-loop numbers toward the Current Goal.

## Physical design

OpenROAD Flow Scripts + SKY130HD was used to generate:

```
results/sky130hd/single_cycle_cpu/base/6_final.gds
```

These results come from an earlier `single_cycle_cpu` run. Neither the results nor the ORFS config are committed, so the run can't be reproduced from this repository.

## Tools

- OSS CAD Suite (Icarus, Yosys, GTKWave)
- OpenROAD Flow Scripts + SKY130 (Docker)
- KLayout

## Next steps

- Merge `feat/pipeline-div` → `feat/mmu-page-fault` → `feat/satp`, then `feat/icache`, into `integrate/core-v1` and re-run `make test`
- Benchmark `core_top` (CPI, then a request-loop workload for the Current Goal)
- S/U privilege modes and an instruction-side MMU
- Re-run physical design on the integrated core
