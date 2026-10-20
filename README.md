# RTL-to-GDS RISC-V (Vardhan)

Open-source RV32 processor development: architecture → RTL → verification → physical design (SkyWater 130 nm).

## Current Goal

A single-core core capable of running a minimal nginx-style benchmark (tiny bare-metal HTTP server or equivalent request-loop microbenchmark). Full nginx/Linux is out of scope; a measurable request-per-second style workload on the core is the target.

**Already working (on `integrate/core-v2` @ `04ed8cd`, not yet merged into `main`):**
- 3-stage pipelined RV32I core with MUL and DIV/DIVU/REM/REMU
- L1 D-cache and L1 I-cache
- M/S/U privilege modes with S-mode CSRs, trap delegation, MRET/SRET
- Sv32 MMU on both data and fetch, with `satp`, SFENCE.VMA and precise page faults
- A SoC with an 8N1 UART, a timer → irq_ctrl → MEI interrupt path, and 64 KiB main RAM
- `sw/nginx_lite`: a freestanding C program that answers one HTTP request over the UART in simulation

**Remaining gaps:**
- No request-rate measurement yet. nginx-lite is a functional pass/fail test that serves a single request; it reports no requests per second.
- MULH/MULHSU/MULHU are not supported.
- The SoC instantiates the core without the MMU (`USE_MMU=0`) and does not cache main RAM.
- PPA numbers need a re-run on the current RTL.

## Current status (`integrate/core-v2` @ `04ed8cd`)

Every row was checked in the RTL and by running `make test` on a clean checkout of `04ed8cd` (Icarus Verilog 12.0, Yosys 0.52); all suites pass. `origin/main` is still at `ba15d11`.

| Feature | Status | Evidence |
|---------|--------|----------|
| RV32I ALU / decoder / imm_gen, single-cycle reference CPU | Verified | `make test-unit`: all pass (incl. `sc_full_tb`, legacy `soc*.sv`) |
| Integrated pipeline (`rtl/core/core_top.sv`) | Verified, **3-stage** | IF / ID / EX+MEM+WB. Bypass from EX into ID; branches, jumps, traps, `satp` writes, SFENCE.VMA and FENCE.I flush and redirect. `make test-integration`: all 9 core tests pass |
| MUL | Verified, `MUL` only | Iterative `mul.sv` in EX, which stalls the pipeline. Integration: 6*7=42 plus a dependent use. `MULH/MULHSU/MULHU` trap as illegal instructions |
| DIV/DIVU/REM/REMU | Verified | `div_unit.sv` + restoring `div.sv`, 33 cycles per op in EX. CORE DIV: PASS (18 divides); `div_unit_tb` passes |
| L1 D-cache | Verified | `dm_cache.sv`: direct-mapped, 64 × 16 B, flop arrays (no SRAM macro). Blocking 4-beat refill, one miss at a time. Caches loads in 0x000–0x1FF only. Stores are write-through; a hit updates the cached word, a miss does not allocate. `make test-cache`: refill 25/25 |
| L1 I-cache | Verified | `icache.sv`: direct-mapped, 8 × 16 B (128 B) by default, flop arrays. Physically indexed and tagged, placed after fetch translation, with FENCE.I invalidation. Enabled by default (`USE_ICACHE=1`). `make test-cache`: icache 32/32; `core_icache_tb` / `core_icache_mmu_tb` pass with the I-cache on and off |
| M-mode CSRs, traps, interrupts | Verified | `csr_file.sv` + `priv_unit.sv`: priv unit tests 81/81 |
| M/S/U modes, S-mode CSRs, delegation, SRET | Verified | sstatus/sie/stvec/sscratch/sepc/scause/stval/sip/satp, medeleg/mideleg, MPRV/SUM/MXR/TSR. `make test-priv`: PRIV MODES 182/182, SMODE 207/207, CORE PRIV MMU 36/36, CORE SMODE 36/36 |
| Sv32 MMU (data + fetch) | Verified in the core (`USE_MMU=1`) | Two `sv32_mmu` instances, each with a 4-entry TLB and a shared-bus page-table walker. `make test-mmu`: 34/34. CORE SATP, CORE IFETCH (fetch page faults, cause 12), CORE FETCH PRIV and CORE PAGE FAULT (causes 13/15) all pass |
| `satp` + SFENCE.VMA | Verified | A `satp` write or SFENCE.VMA flushes both TLBs (flush-all, no ASID). CORE SATP and CORE SFENCE pass |
| SoC: timer → irq_ctrl → MEI | Verified | `soc_core_top` wires `irq_ctrl.irq` to `meip`; `mtip`/`msip` are tied to 0. SOC TIMER IRQ (MEI): PASS |
| SoC: UART | Verified | `rtl/soc/uart.sv`: 8N1, TX/RX FIFOs, STATUS, BAUDDIV at 0x230, plus the legacy TX alias at 0x200. UART TEST: PASS |
| nginx-lite SoC test | Verified (functional) | `tb/soc/soc_sw_tb.sv` with MODE=0 (GET → 200) and MODE=1 (POST → 404): both PASS. See [nginx-lite test](#nginx-lite-test) |
| MMU inside the SoC | Partial | `soc_core_top` defaults to `USE_MMU=0`. Only `core_int_tb` builds the SoC with `USE_MMU=1`; nginx-lite runs with the MMU off, in M-mode |
| Request-rate (req/s) benchmark | Missing | No test reports requests per second |
| PPA on current RTL | Stale | [`docs/ppa/core-v2-sky130hd.md`](docs/ppa/core-v2-sky130hd.md) was measured at `53f6ec9`, before the I-cache and PPA branches were merged. Re-run pending. `make test-ppa-check` (Yosys ALU equivalence + MUL random vectors) passes |
| GDS | Not reproducible from repo | Only an older `single_cycle_cpu` GDS is reported (commit `f8f2392`); it is not committed. By default the core-v2 ORFS flow stops at CTS (no routing, no GDS) |

## nginx-lite test

`sw/nginx_lite/` is a freestanding C program built with `-march=rv32i_zicsr -mabi=ilp32`, so it executes no M-extension instructions. It runs on `soc_core_top` from main RAM at `0x0001_0000`; the Boot ROM stub at the reset vector jumps there. The program:

1. prints `Hello from RISC-V\r\n` on the UART;
2. reads one HTTP request (request line plus headers up to the blank line) from UART RX;
3. answers `HTTP/1.0 200 OK ... Hello from RISC-V nginx-lite` for `GET /`, otherwise `HTTP/1.0 404 Not Found`;
4. writes the exit code to GPIO and sets DONE.

`tb/soc/soc_sw_tb.sv` decodes the serial `uart_tx` line, sends the request on `uart_rx`, and compares the whole TX stream byte for byte. It is a functional test of one request. It runs in M-mode with the MMU off, the I-cache on, and main RAM uncached, and it does not measure throughput.

The test uses the committed `sw/nginx_lite/nginx_lite.hex`. Rebuilding it needs `riscv64-unknown-elf-gcc` (`make -C sw/nginx_lite`), which was not available when this README was checked. The hex was therefore not rebuilt or compared against the C source.

## Performance numbers

There is no CPI benchmark for `core_top` yet. Cycle counts printed by the current tests, which are directed tests and not benchmarks:

| Test | Result |
|------|--------|
| `core_icache_tb`, 56 instructions retired | 109 cycles with I-cache (8 refills), 83 cycles with `USE_ICACHE=0` (combinational imem) |
| `core_div_tb`, 18 divides | 647 cycles, 33 cycles per DIV |
| `tb_branch_loop` (standalone `pipeline_branch` model) | CPI 1.909 |

Historical baselines from `ba15d11`: single-cycle CPI 1.00, simplified `pipeline_top` ≈1.77 (fixed 40-cycle run of `bench_pipe.sv`).

## Repository layout

```
ARCHITECTURE.md        As-built block overview of core-v2
docs/                  Phase 0 specs; memory_map.md = as-built SoC map; ppa/ = PPA report (stale)
rtl/core/core_top.sv   Integrated core: pipeline, D$/I$, priv unit, MUL/DIV, optional I/D Sv32 MMUs
rtl/cpu/               ALU, decoder, imm_gen, regfile, branch unit, mul, div, div_unit, single-cycle CPU
rtl/cache/             dm_cache.sv (D-cache), icache.sv (I-cache)
rtl/priv/              csr_file.sv, priv_unit.sv (M/S/U, delegation, SFENCE.VMA)
rtl/mmu/               sv32_mmu, sv32_tlb, sv32_ptw, sv32_perm_check
rtl/soc/               soc_map_pkg, addr_decode, timer, irq_ctrl, uart, soc_core_top, soc_top (single-cycle)
rtl/pipeline/          Older standalone pipeline models (test vehicles)
sw/nginx_lite/         Freestanding C program + committed hex
syn/                   Yosys/OpenSTA (synth_core.sh), ORFS sky130hd flow (orfs/), VCD power (power/)
tb/                    unit/ cpu/ pipeline/ cache/ priv/ mmu/ soc/ integration/ ppa/
Makefile               make test and per-suite targets
```

## How to run tests

Requirements:
- Icarus Verilog (checked with 12.0), `bash` and `python3`.
- Yosys (checked with 0.52) for `test-ppa-check`.
- `test-ppa-check` reads `rtl/cpu/alu.sv` at commit `53f6ec9` with `git show`, so it needs a git checkout that contains that history. A `git archive` copy fails with "ALU EQUIV: FAIL".

```bash
make test               # all suites; ends with "== make test: all suites passed"
make test-unit          # ALU, decoders, imm_gen, mul, div, div_unit, single-cycle CPU, legacy SoCs
make test-pipeline      # standalone pipeline models (6 tests)
make test-cache         # dm_cache refill, icache unit, core I$ (+MMU) tests with I$ on/off
make test-priv          # priv unit, priv modes, S-mode, core priv+MMU, core S-mode
make test-mmu           # Sv32 MMU unit test (34 tests)
make test-soc           # irq_ctrl, timer IRQ, soc_top, UART, nginx-lite (x2), SoC timer IRQ
make test-integration   # core_int (MMU off/on), core MMU, DIV, page fault, satp, ifetch, fetch-priv, sfence
make test-ppa-check     # ALU formal equivalence vs 53f6ec9 + MUL random vectors + generic cell counts
```

Simulator outputs go to `$SIM_OUT` (default `/tmp/riscv_sim`). The generator scripts (`tb/integration/gen_prog.py`, `tb/soc/gen_timer_irq_prog.py`) rewrite their committed `.hex` files on every run. To keep a working tree clean, run the tests in a throwaway clone:

```bash
git clone -q . /tmp/rv && make -C /tmp/rv test SIM_OUT=/tmp/rv/out
```

## Known limitations

- **3-stage pipeline.** EX also does memory access and writeback, and the only bypass is EX→ID. MUL (32 cycles), DIV (33 cycles), every load and store, and I-cache misses stall the pipeline. There is no branch prediction; taken branches flush in EX.
- **M extension incomplete.** `MULH/MULHSU/MULHU` trap as illegal instructions.
- **Caches are small, blocking and made of flops.** D-cache is 1 KiB, I-cache is 128 B. There is no SRAM macro, so the arrays become standard cells. The D-cache caches only 0x000–0x1FF (Boot ROM + SRAM); main RAM at 0x0001_0000 and MMIO are uncached. There is no write-allocate and no ready/valid memory arbiter: refills, page-table walks and uncached accesses share one combinational-read bus.
- **MMU.** No ASID, no hardware A/D update (A=0, or a store with D=0, page-faults), no PMP/PMA, flush-all only, and `mstatus.TVM` is not implemented. `core_top` truncates the 34-bit physical address to 32 bits.
- **Privileged spec subset.** WFI is a NOP. ECALL from M cannot be delegated. The SoC drives only MEI: `mtip`/`msip` are tied to 0, so the timer interrupts through irq_ctrl as an external interrupt, not as MTI.
- **SoC defaults.** `soc_core_top` uses `USE_MMU=0`. The ROM and SRAM are 256 B each, and main RAM is 64 KiB. Unmapped accesses set a sticky `bus_err`; they do not cause an access-fault trap.
- **No throughput benchmark.** nginx-lite serves exactly one request and reports no requests per second.
- **Physical design.** The core-v2 ORFS flow (`syn/orfs/run.sh`) runs synth → floorplan → place → CTS by default (`TARGETS`), with no routing or GDS. The published numbers are stale (see below). The memories (`imem`/`dmem`) are outside `core_top` and are modelled as combinational-read.

## Physical design / PPA

- **Flows.** `syn/orfs/` is the sky130hd ORFS flow (synth, floorplan, place, CTS, then `ppa_report.tcl`). `syn/synth_core.sh` (Yosys + OpenSTA) and `syn/power/` (VCD activity) are still in the tree. The older `flow/sky130hd/` was removed in `65f5683`.
- **Stale numbers.** [`docs/ppa/core-v2-sky130hd.md`](docs/ppa/core-v2-sky130hd.md) and `syn/PPA_RESULTS.md` predate the current RTL. They were measured at `53f6ec9` and on `feat/ppa-pipeline` respectively, before the I-cache was merged. Treat them as stale until they are re-run.
- **Older GDS.** An earlier `single_cycle_cpu` GDS (`results/sky130hd/single_cycle_cpu/base/6_final.gds`) is reported in commit `f8f2392`, but it is not committed.

## Tools

- Icarus Verilog, Yosys (OSS CAD Suite); GTKWave
- OpenROAD Flow Scripts + SKY130 (`openroad/orfs` Docker image)
- KLayout
- `riscv64-unknown-elf-gcc` (only to rebuild `sw/nginx_lite`)

## Next steps

- Merge `integrate/core-v2` into `main`
- Request-loop benchmark on nginx-lite: multiple requests and a cycles-per-request metric
- Re-run the sky130hd PPA on the current RTL; consider SRAM macros for the cache arrays
- MULH*, the MMU enabled in the SoC, caching of main RAM
