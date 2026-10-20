# sw/perf — SoC microbenchmarks

Small self-contained benchmarks that run on `rtl/soc/soc_core_top.sv`
(integrated pipelined `core_top`: I-cache, D-cache, MUL/DIV, UART, 64 KiB RAM).
No RTL is changed. Cycle and instruction counts come from the core's own
`mcycle`/`minstret` CSRs; the testbench adds hierarchical cache probes
(the caches have no counters).

## Run

```bash
make perf            # = bash tb/perf/run_perf.sh: all PERF lines + per-check verdicts
make test-perf       # the same run as part of `make test` (verdict lines only)
make test            # full regression, now includes test-perf
make perf-sw         # rebuild sw/perf/perf.hex (needs riscv64-unknown-elf-gcc)
```

`run_perf.sh` uses the committed `perf.hex`, so no RISC-V toolchain is needed
to run it. Full log: `$SIM_OUT/perf/perf_tb.log` (default `/tmp/riscv_sim/perf/`).
Takes about 40 s in Icarus (~380k cycles, most of them spent waiting on the UART).

## Files

| File | Purpose |
|------|---------|
| `bench.S` | timed kernels (rv32im): CPI loop, I-cache small/big loops, strided loads, array sum/copy, MUL/DIV single op and chains |
| `main.c` | driver: runs the kernels, checks every result, prints `PERF ...` lines, web-like request handler |
| `Makefile` | build (`-march=rv32i_zicsr_zifencei`; M ops only in `bench.S`); runtime shared with `../nginx_lite` (crt0, link.ld, uart, memset/memcpy, bin2hex) |
| `perf.hex` | **committed** build output (main-RAM image) |
| `../../tb/perf/perf_tb.sv` | SoC testbench: decodes UART TX, opens/closes probe windows on GPIO markers, functional checks |
| `../../tb/perf/run_perf.sh` | compile + run with Icarus (`iverilog -g2012`) |

## Method

* Each kernel window is `csrr minstret; csrr mcycle; <body>; csrr mcycle; csrr minstret`.
  The empty window (1 cycle, 3 instructions) is subtracted from every number.
* Kernels are run once to warm the I-cache, then measured, except the
  explicit cold runs (after `fence.i`, which invalidates the I-cache).
* MUL/DIV latency = single-op window - single-ADD window + 1.
* TB probe windows: `GPIO(0x204) <- 0x5A0000id` opens, `0x5B0000id` closes.
  They include ~7 marker instructions on each side, so their cycle and
  retired counts are a little above the program's own numbers.
  I-cache miss = refill start; I-cache hit = fetch accepted from the cache;
  D-cache hit/miss = lookup with `req_valid`; `dbus_reads` = data-bus read cycles.
* PASS/FAIL is functional only (results, HTTP responses, exit code, bus/UART
  errors). There are no speed thresholds.

## Results (measured, Icarus, 1c09949, UART 4 clocks/bit)

| Benchmark | Result |
|-----------|--------|
| CPI loop (8 ALU + not-taken beq + addi + taken bne), 200 iters | 2200 instr, 2609 cycles, **CPI 1.186** (13.05 cycles/iter: +2 per taken branch) |
| I-cache, 72 B loop body | cold 1 iter: 41 cycles (9 misses in tb window); warm 50 iters: 20.42 cycles/iter, CPI 1.131, 9 misses total |
| I-cache, 264 B loop body (> 128 B cache) | 50 iters: 136.02 cycles/iter, CPI 2.059, 854 misses (≈17/iter, every line every iteration) |
| D-cache SRAM, 32 seq. loads | cold 294 cycles (8 misses / 24 hits), warm 262 (32 hits): 32 cycles = 4 per miss |
| D-cache SRAM, 1 load per line (8) | cold 102 (8 misses), warm 70 (8 hits) |
| Uncached main RAM, 32 seq. loads | 230 cycles: **1 cycle/load faster than a D-cache hit** |
| MUL, DIV, DIVU, REM, REMU latency | **34 cycles each**, for every operand case (incl. div-by-zero, INT_MIN/-1, zero operands) |
| 16 dependent / independent MUL | 34.00 / 34.25 cycles per op (no overlap) |
| 8 dependent / independent DIV | 34.00 / 34.50 cycles per op |
| MUL then dependent ADD | 35 cycles (result forwarded, no extra bubble) |
| Array sum (lw x4 unrolled), 1024 words, main RAM | 3338 cycles, 3.260 cycles/word, 1.227 B/cycle |
| Array copy (4 lw + 4 sw), 1024 words | 3594 cycles, 3.510 cycles/word, 1.140 B/cycle (8 KiB moved) |
| Array sum, 64 words in D-cached SRAM, warm | 4.375 cycles/word, 0.914 B/cycle |
| Web loop: parse + build response, 4 requests | 2433 / 1998 / 1050 / 1005 cycles (200, 200, 404, 501); avg 1621.5; avg 4530.25 incl. UART TX |

Observations:

* MUL is as slow as DIV (iterative multiplier, 34 cycles, data-independent).
  It and DIV stall the whole pipeline, so independent ops do not overlap.
* With this SoC's zero-wait main RAM, the D-cache only adds latency: a hit
  costs one extra cycle (the response is registered) and a miss costs 4 more.
  Only `[0x0, 0x200)` (ROM + 256 B SRAM) is cacheable and it is smaller than the
  1 KiB D-cache, so a working set larger than the cache (thrash test) cannot
  be built. That case is skipped.
* The web handler is rv32i C (`-Os`): byte-at-a-time parsing and copying, and
  the Content-Length formatting goes through libgcc software divide. The 200
  responses (91 B, with formatting) cost about 2x the 404/501 ones (45-51 B).
  The cost was not broken down further.
