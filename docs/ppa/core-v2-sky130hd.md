# Quick PPA: integrated core (`integrate/core-v2` @ `53f6ec9`, STALE) on sky130hd

A quick synthesis, floorplan, placement and CTS run in OpenROAD-flow-scripts (ORFS) to get first
area, timing and power numbers. There is no global or detailed routing, so the timing and power
below use placement-estimated parasitics.

> **⚠ STALE — DO NOT CITE. Re-run pending.** Every area, timing and power number in this report was
> measured on **`53f6ec9`**, using the since-removed `split_async_flush.py` workaround. That was
> before the I-cache (`feat/icache-v2`) and the PPA refactor branches (`feat/ppa-alu-regfile`,
> `feat/ppa-pipeline`) were merged, so the numbers do not describe the current
> `integrate/core-v2` RTL (`04ed8cd`). No numbers have been measured since. The flow now lives in
> `syn/orfs/`; its default clock is 10 ns, so use `CLK_PERIOD_NS=20` to reproduce the 50 MHz setup below.
> `syn/PPA_RESULTS.md` (10 ns, `feat/ppa-pipeline`) also predates the I-cache merge.

| | |
|---|---|
| RTL commit | `53f6ec9` (`integrate/core-v2`) |
| Top | `core_top` (`rtl/core/core_top.sv`) |
| Platform | sky130hd, `sky130_fd_sc_hd__tt_025C_1v80` (TT, 25 °C, 1.8 V) |
| Clock target | 20 ns (50 MHz) on `clk`. I/O delays are 20 % of the period (4 ns in, 4 ns out) |
| Floorplan | `CORE_UTILIZATION = 40`, aspect ratio 1, `PLACE_DENSITY = 0.60` |
| Tools | `openroad/orfs:latest` image (digest `sha256:b0f9cd13…`, built 2026-10-19), Yosys 0.68+post with the built-in slang SV front end (`SYNTH_HDL_FRONTEND = slang`), OpenROAD from the same image (it reports its version as "unknown") |
| Flow | `synth`, `floorplan`, `place`, `cts`, then `ppa_report.tcl` (now `syn/orfs/ppa_report.tcl`) (STA and power on `4_cts.odb`, `estimate_parasitics -placement`, propagated clocks) |

## What was synthesized

`core_top` is the pipeline with the L1 D-cache (`dm_cache`), the priv unit and CSR file, MUL,
and DIV/REM. Its instruction and data memories are **outside** the design: `imem_*` and `dmem_*`
are top-level ports, and no ROM, SRAM or SoC (`soc_core_top`) is included. Testbenches are not
included.

* **base**: `core_top` with default parameters (`USE_MMU = 0`, so there is no MMU hardware).
* **mmu**: `core_top` with `USE_MMU = 1` (D-side and I-side Sv32 MMUs, each with a 4-entry TLB).

The **D-cache arrays and the register file are flip-flops.** The D-cache data
(64 × 4 × 32 b = 8192 b), tags (64 × 22 b) and the 32 × 32 register file are plain SV arrays.
There is no SRAM macro, so they become standard cells (`SYNTH_MEMORY_MAX_BITS` was raised from
4096 to 16384 to allow this). The D-cache alone is about **75 % of the cell area** (see the
table below). A real tape-out would use an SRAM macro (for example from `sky130ram`/OpenRAM)
for the cache data array, so these numbers are a pessimistic upper bound for area and power.

### RTL issue: the unmodified RTL does not synthesize

Five `always_ff` blocks combine the asynchronous reset with a synchronous flush in a single
condition:

```systemverilog
always_ff @(posedge clk or negedge rst_n)
    if (!rst_n || flush) begin ... end else ...
```

These are `rtl/core/core_top.sv` lines 117 and 185 (both in the synthesized core), plus the
standalone `rtl/pipeline/if_id.sv`, `id_ex.sv` and `pipeline_branch.sv`, which are not
synthesized here. Icarus simulates this fine, but both Yosys front ends reject it:

* yosys-slang: `rtl/core/core_top.sv:117:9: error: condition cannot be matched to any signal from the event list` (the same error at `:185:9`)
* Yosys `read_verilog -sv`: `ERROR: Multiple edge sensitive events found for this signal!`

The RTL was **not changed** at the time. For this run, a `split_async_flush.py` script (since removed) made a
synthesis-only copy of `rtl/` in the work directory. In that copy, each of those blocks is
rewritten into the equivalent `if (!rst_n) <reset> else if (flush) <same values> else ...`
(async reset plus a synchronous flush, which is what the original code does in simulation). The
full `make test` regression passes on that rewritten copy. *Update:* the two `core_top.sv` blocks
have since been split in the RTL itself, so `core_top` now synthesizes as-is and the script was
removed. The standalone `rtl/pipeline/*` files (not synthesized) still use the combined form.

## Results

### Area / cells

| | base (USE_MMU=0) | mmu (USE_MMU=1) |
|---|---|---|
| Synthesized cell area (Yosys) | **520,084 µm²** | 572,798 µm² |
| Synthesized cell count | **33,527** | 45,721 |
| ↳ flip-flops | 11,661 (9,726 `edfxtp_1`, 1,923 `dfrtp_1`, 12 `dfstp_2`) | 12,585 (10,134 `edfxtp_1`, 2,435 `dfrtp_1`, 16 `dfstp_2`) |
| ↳ combinational (non-flop) | 21,866 | 33,136 |
| Latches | 0 | 0 |
| Die area | 1141.2 × 1141.2 µm = 1.302 mm² | 1194.5 × 1194.5 µm = 1.427 mm² |
| Core area | 1,294,429 µm² | 1,416,692 µm² |
| Utilization after floorplan | 40.1 % (519,281 µm²) | 40.1 % (569,015 µm²) |
| Utilization after placement | 42 % (543,829 µm²) | 42 % (593,747 µm²) |
| Utilization after CTS | 45 % (584,290 µm²) | 45 % (638,529 µm²) |
| Instances after CTS | 51,876 (17,220 tap cells) | 65,091 (18,877 tap cells) |
| Clock buffers / inverters after CTS | 1,564 / 651 (11,661 sinks) | 1,733 / 711 (12,513 sinks) |

Synthesized area by module, for the base variant (Yosys, hierarchical stat):

| Module | Cells | Area (µm²) | Share |
|---|---|---|---|
| `dm_cache` (u_dcache) | 20,039 | 393,245 | 75.6 % |
| `core_top` local (regfile, pipeline regs, glue) | 6,691 | 71,333 | 13.7 % |
| `priv_unit` (incl. `csr_file` 19,381) | 2,678 | 22,564 | 4.3 % |
| `div_unit` (incl. `div` 8,861) | 1,472 | 12,378 | 2.4 % |
| `alu` | 1,404 | 9,694 | 1.9 % |
| `mul` | 743 | 7,338 | 1.4 % |
| `branch_unit`, `decoder`×2, `imm_gen` | 587 | 4,049 | 0.8 % |

In the mmu variant, each `sv32_mmu` instance is 1,293 cells / about 17,100 µm² (TLB about
9,030 µm², PTW about 3,970 µm²). The D-cache is 28,820 cells / about 403,000 µm² there.

Most common cells after CTS (base): `edfxtp_1` ×9,726 (292,060 µm², the cache arrays),
`mux4_2` ×3,318 (74,727 µm², array read muxes), `dfrtp_1` ×1,915 (47,921 µm²), `clkbuf_16`
×1,313 (32,857 µm²), `nand2_1` ×4,319 (16,212 µm²), `mux2i_1` ×1,084 (10,850 µm²), `buf_4`
×1,328 (9,970 µm²).

### Timing (50 MHz target)

| | base | mmu |
|---|---|---|
| WNS / TNS (setup), after place, ideal clock | 0.00 / 0.00 ns (worst slack +7.38 ns) | 0.00 / 0.00 ns (worst slack +6.89 ns) |
| WNS / TNS (setup), after CTS, propagated clock | **0.00 / 0.00 ns (worst slack +6.95 ns)** | 0.00 / 0.00 ns (worst slack +6.84 ns) |
| Worst hold slack after CTS | +0.40 ns | +0.40 ns |
| Min period (`report_clock_min_period`) after CTS | **11.99 ns ≈ 83.4 MHz** | 13.16 ns ≈ 76.0 MHz |
| Min period after place (ideal clock) | 12.62 ns ≈ 79.3 MHz | 13.11 ns ≈ 76.3 MHz |

**Verdict: 50 MHz is met** with about 7 ns of setup margin and no hold, slew or cap violations
reported by `report_check_types -violators`. `check_setup` reported no unconstrained endpoints,
no combinational loops and no missing clocks.

Critical paths after CTS:

* **reg → reg (base, slack +8.02 ns, data path ≈ 11.6 ns):** `alu_src_b_ex` flop → ALU operand mux
  → ALU adder → D-cache index decode / `mux4` read tree → tag compare (hit) → write enable of a D-cache
  data word (`u_dcache/data[0][69]`, `edfxtp_1` DE pin). This is the store-hit update of the
  flop-based cache array, all in the single EX/MEM cycle.
* **reg → reg (mmu, slack +6.84 ns):** the same shape, `instr_ex[2]` → ALU → D-cache index / hit
  → `u_dcache/data[47][12]` DE.
* **reg → output (base, slack +6.95 ns):** `alu_src_b_ex` → ALU → `dmem_re` (the memory request is a
  combinational function of the EX stage).
* **Input → output feed-through:** `mtip` (mmu: `msip`) → priv unit → `dmem_re` (slack +7.38 /
  +8.59 ns). The interrupt inputs reach the bus request outputs through the priv unit's trap logic in
  the same cycle, with no register in between.
* **rst_n recovery:** the async reset goes through about 10 buffers to 11.6k flops, with +10.3 ns
  slack.

### Power (base, after CTS, 50 MHz)

| Group | Internal | Switching | Leakage | Total |
|---|---|---|---|---|
| Sequential | 27.7 mW | 0.118 mW | 0.115 µW | 27.9 mW (47.9 %) |
| Combinational | 1.67 mW | 5.13 mW | 0.062 µW | 6.80 mW (11.7 %) |
| Clock | 13.5 mW | 9.95 mW | 0.020 µW | 23.5 mW (40.4 %) |
| **Total** | **42.9 mW** | **15.2 mW** | **0.197 µW** | **58.1 mW** |

mmu variant total: 76.5 mW (internal 50.4 mW, switching 26.1 mW, leakage 0.229 µW).

**Activity assumption:** OpenROAD `report_power` used OpenSTA's built-in default (vectorless)
activity. No VCD/SAIF and no `set_power_activity` were applied. The clock is 50 MHz and
parasitics are placement-estimated. Treat these as rough relative numbers. The flop-based cache
(about 9.7k always-clocked flops, with no clock gating) dominates the sequential and clock power.

## Caveats

* Not routed, so there are no extracted parasitics. Expect some slack loss after global and
  detailed routing.
* Only the single TT corner was run. No SS/FF corners and no OCV derates.
* The memories (`imem`/`dmem`) are external and combinational-read in the RTL. The real
  flop → `dmem_addr` → memory → `dmem_rdata` → flop loop is only covered here by the assumed
  4 ns + 4 ns I/O budget. With a real synchronous SRAM, the pipeline would need a registered
  memory interface.
* The numbers are for the synthesis-only rewritten copy of `rtl/` described above (the
  `async reset || flush` blocks are split). At `53f6ec9` the RTL did not elaborate in Yosys as-is
  (fixed since).
* The I-cache was not yet part of `integrate/core-v2` at `53f6ec9`, so it is not included
  (it is now: `feat/icache-v2`, in the current `syn/orfs` file list).

## Reproduce

Run inside the `openroad/orfs` image (or any ORFS install with Yosys 0.67+ / `read_slang`):

```sh
cd <repo>
# full run (synth, floorplan, place, cts) + post-CTS PPA report, 50 MHz as in this report
CLK_PERIOD_NS=20 FLOW_VARIANT=base syn/orfs/run.sh $PWD/rtl /tmp/riscv_ppa
# report only, on an existing run
CLK_PERIOD_NS=20 FLOW_VARIANT=base syn/orfs/report_only.sh $PWD/rtl /tmp/riscv_ppa
# FLOW_VARIANT=mmu for USE_MMU=1
```

The generated outputs (netlists, ODB, logs) stay in `WORK_HOME` and are not committed.
