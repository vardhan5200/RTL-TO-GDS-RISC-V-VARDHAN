# Architecture (as built)

This file describes what is implemented on `integrate/core-v1` @ `aa8cbde`. The original Phase 0 target design (5-stage pipeline, split I/D caches, ready/valid interconnect) is in [`docs/architecture.md`](docs/architecture.md). For the as-built address map and peripheral registers, see [`docs/memory_map.md`](docs/memory_map.md). Features that exist only on unmerged branches are marked *(unmerged)*.

```
            imem (combinational ROM read; no I-cache, no I-MMU)
              |
+-------------v--------------------------------------------------+
| core_top (rtl/core/core_top.sv)                                |
|                                                                |
|  IF ──> ID ──────────────> EX / MEM / WB                       |
|  PC     decoder, imm_gen   ALU, branch_unit (flush on taken)   |
|         regfile read       mul (iterative, stalls EX)          |
|         EX->ID bypass      priv_unit: CSRs, traps, IRQs, MRET  |
|                            LSU: [sv32_mmu, USE_MMU=1] ->       |
|                                 dm_cache (loads 0x000-0x1FF)   |
|                                 or uncached / store bus access |
+--------------------------------+-------------------------------+
                                 | one data bus (cache refill > PTW > core)
+--------------------------------v-------------------------------+
| soc_core_top (rtl/soc/)  addr_decode + soc_map_pkg             |
|  ROM 0x000-0x0FF | SRAM 0x100-0x1FF | UART 0x200 | GPIO 0x204  |
|  DONE 0x208 | Timer 0x210-0x21F | IRQ ctrl 0x220-0x22F         |
|  irq_ctrl.irq -> core meip   (timer is IRQ source 0)           |
+----------------------------------------------------------------+
```

## Pipeline (`rtl/core/core_top.sv`)
- **3 stages:** IF, ID, and a combined EX/MEM/WB stage that is also the commit point. Writeback happens at the end of EX, and an EX→ID bypass resolves back-to-back RAW dependences.
- **Control flow:** branches and jumps resolve in EX. A taken branch, a trap, or MRET flushes IF/ID. There is no branch prediction.
- **Stalls:** MUL (32-cycle `mul.sv`) and every load or store stall the pipeline until they finish.
- **ISA:** RV32I + `MUL`. MULH* and DIV/REM trap as illegal. DIV/DIVU/REM/REMU are *(unmerged: `feat/pipeline-div`)*.
- Standalone pipeline models in `rtl/pipeline/` (`pipe_min_working`, the 5-stage `pipeline_cpu`, `pipeline_branch`) are test vehicles, not the integrated core.

## Caches
- **D-cache:** `rtl/cache/dm_cache.sv`. Direct-mapped, 64 lines × 4 words (1 KiB), blocking 4-beat refill, one miss at a time. Only loads in [0x000, 0x200) are cached. Stores are write-through, update the cached word on a hit, and do not allocate.
- **I-cache:** none. The core fetches from imem combinationally. An 8-line direct-mapped I-cache is *(unmerged: `feat/icache`)*.

## Privileged unit (`rtl/priv/`)
- `priv_unit.sv` + `csr_file.sv`, machine mode only.
- **CSRs:** mstatus (MIE/MPIE, MPP=M), misa (RV32IM), mie, mip, mtvec (direct or vectored), mscratch, mepc, mcause, mtval, mcycle/minstret and their read-only aliases, and the ID CSRs.
- **Exceptions:** illegal instruction (2), EBREAK (3), ECALL-M (11).
- **Interrupts:** MEI > MSI > MTI, taken at an instruction boundary. MRET is supported, and WFI is a NOP.
- **Not implemented:** S/U modes, `satp` CSR *(unmerged: `feat/satp`)*, page-fault traps *(unmerged: `feat/mmu-page-fault`)*.

## MMU (`rtl/mmu/`)
- `sv32_mmu` = 4-entry fully associative TLB (`sv32_tlb`) + page-table walker (`sv32_ptw`) + permission check (`sv32_perm_check`). It supports 4 KiB pages and 4 MiB megapages.
- It is used only on the **data side**, when `USE_MMU=1`. `satp` and `priv` come from core ports that `soc_core_top` ties to 0 / M, so the MMU acts as a passthrough there.
- A fault squashes the access and sets the sticky `mmu_fault` output; no trap is taken.
- **Limitations:** no ASID, no A/D update, no PMP, no MPRV, SUM/MXR tied to 0, and the TLB flush is not driven.

## SoC (`rtl/soc/`)
- `soc_map_pkg.sv` is the single source of truth for the memory map, and `addr_decode.sv` routes accesses.
- Peripherals: `timer.sv` (COUNT/COMPARE/CTRL/STATUS) and `irq_ctrl.sv` (8 sources: PENDING/ENABLE/ACK/CLAIM).
- Unmapped accesses and ROM writes set a sticky `bus_err`.
- `soc_core_top.sv` hosts `core_top`. `soc_top.sv` hosts the older `single_cycle_cpu`, which takes no interrupts.

## Physical design
- An earlier `single_cycle_cpu` was taken through OpenROAD Flow Scripts on SKY130HD (reported in commit `f8f2392`). Neither the results nor the flow config are committed.
- `core_top` has not been through physical design yet.
