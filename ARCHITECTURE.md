# Architecture (as built: `integrate/core-v2` @ `04ed8cd`)

This file describes what is implemented. The original Phase 0 target (a 5-stage pipeline, 1 KiB split caches, a ready/valid interconnect) is in [`docs/architecture.md`](docs/architecture.md). For the as-built address map and peripheral registers, see [`docs/memory_map.md`](docs/memory_map.md).

```
                         imem port (Boot ROM / main RAM, combinational read)
                              ^ refill (4 beats)
+-----------------------------|---------------------------------------------+
| core_top                    |                                             |
|  IF:  PC -> [I-MMU + fetch translation reg] -> [I-cache, PIPT, 8x16 B]    |
|  ID:  decoder, imm_gen, regfile (x1..x31), EX->ID bypass, EX selects      |
|  EX/MEM/WB (commit point):                                                |
|       ALU, branch_unit (redirect/flush), mul (32 cyc), div_unit (33 cyc)  |
|       priv_unit + csr_file: M/S/U, CSRs, traps, delegation, MRET/SRET,    |
|                             SFENCE.VMA, interrupts                        |
|       LSU: [D-MMU] -> D-cache (dm_cache, loads 0x000-0x1FF) or uncached   |
+-----------------------------|---------------------------------------------+
                              | one data bus: D$ refill > PTW (D/I) > core access
+-----------------------------v---------------------------------------------+
| soc_core_top (addr_decode + soc_map_pkg)                                  |
|  ROM 0x000-0x0FF | SRAM 0x100-0x1FF | UART TX alias 0x200 | GPIO 0x204    |
|  DONE 0x208 | Timer 0x210 | IRQ ctrl 0x220 | UART 0x230 | RAM 0x1_0000 64K|
|  timer -> irq_ctrl (src 0) -> irq -> core meip   (mtip = msip = 0)        |
+---------------------------------------------------------------------------+
```

## Pipeline (`rtl/core/core_top.sv`)
- **3 stages:** IF, ID, and EX, which also does memory access and writeback and is the commit point. This is not a 5-stage pipeline.
- **Forwarding:** the EX result is bypassed into ID. ID decodes the EX-stage selects ahead of time and registers them (one-hot result mux).
- **Flush/redirect from EX:** taken branches, jumps, traps, MRET/SRET, `satp` writes, SFENCE.VMA and FENCE.I. There is no branch prediction.
- **Stalls:** the pipeline holds while MUL or DIV runs, while a load or store finishes (D-cache miss, page-table walk, uncached access), and while I-cache refills or I-side translation are in progress.
- **ISA:** RV32I + MUL + DIV/DIVU/REM/REMU + Zicsr + SFENCE.VMA + FENCE.I. MULH/MULHSU/MULHU trap as illegal, and WFI is a NOP.

## Caches (both flop arrays, no SRAM macro)
- **D-cache** (`rtl/cache/dm_cache.sv`):
  - direct-mapped, 64 lines × 16 B, blocking 4-beat refill;
  - caches loads in [`CACHE_BASE`, `CACHE_LIMIT`), which `soc_core_top` sets to 0x000–0x1FF;
  - stores are write-through and update the word on a hit; there is no write-allocate.
- **I-cache** (`rtl/cache/icache.sv`, `USE_ICACHE=1` by default):
  - direct-mapped, `ICACHE_LINES` × 16 B (default 8 lines = 128 B);
  - physically indexed and tagged, looked up after fetch translation;
  - 4-beat refill over the imem port; FENCE.I invalidates all lines.
  - `USE_ICACHE=0` restores the uncached combinational fetch.

## Privileged unit (`rtl/priv/`)
- **Modes:** M/S/U, held in `cur_priv`, which resets to M.
- **CSRs:**
  - M: mstatus (MIE/MPIE/MPP/SIE/SPIE/SPP/MPRV/SUM/MXR/TSR), misa = RV32IMSU, medeleg, mideleg, mie, mip, mtvec, mscratch, mepc, mcause, mtval, counters, ID CSRs.
  - S: sstatus, sie, stvec, sscratch, sepc, scause, stval, sip, satp.
- **Exceptions:** illegal instruction / privilege violation (2), EBREAK (3), ECALL from U/S/M (8/9/11), and MMU faults on fetch, load and store (12/13/15; access faults 1/5/7). MMU faults are precise: they are raised when the instruction reaches EX.
- **Delegation:** exceptions taken in U/S whose `medeleg` bit is set go to S (stvec/sepc/scause/stval); interrupts are delegated through `mideleg`.
- **Interrupts:** taken at an instruction boundary. M-level beats S-level; within a level the order is MEI > MSI > MTI > SEI > SSI > STI.
- **Returns:** MRET (M only) and SRET (S or M; illegal in U, or in S when TSR=1).

## MMU (`rtl/mmu/`, `USE_MMU=1`)
- Two `sv32_mmu` instances, one for data and one for fetch. Each has a 4-entry fully associative TLB, a two-level page-table walker and a permission check, and supports 4 KiB pages and 4 MiB megapages.
- **Translation rules:** translation is on when `satp.MODE` = Sv32 and the effective privilege is below M.
  - Data uses MPP when MPRV=1 in M-mode, and honours SUM/MXR.
  - Fetch uses `cur_priv`.
  - A 1-entry fetch translation register keeps sequential fetches within a page at one instruction per cycle.
- **Flushes:** a `satp` write or SFENCE.VMA flushes both TLBs (flush-all) and the pipeline.
- **Limits:** no ASID, no hardware A/D update, no PMP. `soc_core_top` defaults to `USE_MMU=0`.

## SoC (`rtl/soc/`)
- `soc_map_pkg.sv` is the single source of truth for the map, and `addr_decode.sv` routes accesses.
- **Peripherals:**
  - `timer.sv`: COUNT/COMPARE/CTRL/STATUS;
  - `irq_ctrl.sv`: 8 sources, PENDING/ENABLE/ACK/CLAIM;
  - `uart.sv`: 8N1 with TX/RX FIFOs, DATA/STATUS/BAUDDIV.
- **Program loading:** a main RAM image is loaded with `MEM_FILE` / `+MEM_HEX`. The Boot ROM stub at the reset vector (0x0) jumps to 0x0001_0000.
- **Errors:** unmapped accesses set a sticky `bus_err` and raise no trap.
- `soc_top.sv` is the older SoC built around `single_cycle_cpu`.

## Physical design
- `syn/orfs/` holds the ORFS sky130hd flow for `core_top`. Its default targets are synth, floorplan, place and CTS, followed by a PPA report. Memories are outside the design.
- The published numbers in [`docs/ppa/core-v2-sky130hd.md`](docs/ppa/core-v2-sky130hd.md) are **stale**: they were measured at `53f6ec9` and are awaiting a re-run.
