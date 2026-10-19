# Memory Map

**Status:** Phase 0 — design freeze; §1/§3 updated with as-built SoC map (timer + IRQ controller)  
**Reset PC:** `0x0000_0000`  
**Date:** 2026-10-19

## 1. Address regions (as built — `rtl/soc/soc_top.sv`)

The address map is defined once in `rtl/soc/soc_map_pkg.sv` and decoded by
`rtl/soc/addr_decode.sv` (the single source of truth for region routing).
Everything lives in the low 4 KiB so programs can reach every register with
`x0 + imm12` (e.g. `sw x1, 0x200(x0)`). ROM/SRAM/UART/GPIO/DONE addresses are
unchanged from `soc.sv`; Timer and IRQ controller are new.

| Address range               | Block          | Size      | Access     | Notes                                         |
|-----------------------------|----------------|-----------|------------|-----------------------------------------------|
| `0x0000_0000`–`0x0000_00FF` | Boot ROM       | 256 B (64 words) | Read-only | Reset vector; instruction fetch + data reads. Writes are ignored and set `bus_err` |
| `0x0000_0100`–`0x0000_01FF` | SRAM           | 256 B (64 words) | Read/write | Data memory                              |
| `0x0000_0200`               | UART TX        | 1 word    | Write-only | Low byte transmitted; reads return 0          |
| `0x0000_0204`               | GPIO OUT       | 1 word    | Read/write | Low byte drives `gpio_out`                     |
| `0x0000_0208`               | DONE           | 1 word    | Read/write | Any write sets `done` (sim end flag); read = `done` |
| `0x0000_020C`               | —              | —         | —          | Unmapped (reserved)                           |
| `0x0000_0210`–`0x0000_021F` | Timer          | 4 words   | Read/write | See §3.1; irq source 0                         |
| `0x0000_0220`–`0x0000_022F` | IRQ controller | 4 words   | Read/write | See §3.2; drives SoC `irq` output              |
| everything else             | unmapped       | —         | —          | Reads return `0x0000_0000`; sets `bus_err`    |

**Unmapped access handling.** A load or store to an unmapped address, or a
store to ROM, returns `0x0000_0000` (loads) / is dropped (stores) and sets the
sticky `bus_err` output of `soc_top`; `bus_err_addr` captures the address of
the first error. Both are cleared only by reset. (The CPU does not yet take a
bus-error exception; see §6.)

**Changes vs. `soc.sv`.** UART/GPIO/DONE are decoded on the word address
(`addr[31:2]`) instead of an exact byte compare. No address moved.
`soc_timer.sv` is a standalone legacy demo whose timer registers at
`0x0C`/`0x10` overlap the Boot ROM; it is left untouched, and the timer in
`soc_top` lives at `0x210` instead.

**Phase-0 target map.** The original plan (Boot ROM at `0x0000_0000`,
64 KiB SRAM at `0x1000_0000`, peripherals in 4 KiB pages at `0x2000_0000+`)
remains the target once caches and a real bus exist. Moving to it only needs
the constants in `soc_map_pkg.sv` (and the boot programs, which then need
`lui`) to change.

## 2. Reset and boot

- Reset PC = `0x0000_0000` (start of Boot ROM).
- The linker script and boot image must use the same map.
- Boot ROM contains the initial program; it may copy itself or a larger image into SRAM and jump there.

## 3. Peripheral register layout

All registers are 32-bit, word-accessed. Offsets are relative to the block base.

### 3.1 Timer (`0x0000_0210`, `rtl/soc/timer.sv`)
| Offset | Address  | Register | Access | Reset        | Description                                        |
|--------|----------|----------|--------|--------------|----------------------------------------------------|
| 0x0    | `0x210`  | COUNT    | R      | 0            | Free-running counter, +1 per clock while enabled   |
| 0x4    | `0x214`  | COMPARE  | R/W    | `0xFFFFFFFF` | Match value                                        |
| 0x8    | `0x218`  | CTRL     | R/W    | 1            | bit0 = count enable                                |
| 0xC    | `0x21C`  | STATUS   | R/W1C  | 0            | bit0 = match flag, set when COUNT == COMPARE (and enabled); write 1 to clear. Drives irq source 0 |

### 3.2 Interrupt controller (`0x0000_0220`, `rtl/soc/irq_ctrl.sv`)
8 sources (`N` parameter). Source 0 = timer match flag; sources 1–7 come from
the `ext_irq[6:0]` port of `soc_top` (tied to 0 today).

| Offset | Address  | Register | Access | Reset | Description                                            |
|--------|----------|----------|--------|-------|--------------------------------------------------------|
| 0x0    | `0x220`  | PENDING  | R      | 0     | bit i = source i was seen high (latched)               |
| 0x4    | `0x224`  | ENABLE   | R/W    | 0     | bit i = source i may assert `irq`                      |
| 0x8    | `0x228`  | ACK      | W1C    | —     | Write 1 to bit i to clear PENDING[i]; reads 0          |
| 0xC    | `0x22C`  | CLAIM    | R      | 0     | bit31 = some enabled source pending; bits[7:0] = id of lowest-numbered pending & enabled source (lowest id = highest priority) |

`irq = |(PENDING & ENABLE)` (level, active high). Sources are level-sensitive:
if a source is still high when ACKed it re-pends on the next cycle, so a
handler must clear the cause in the peripheral first, then ACK. A new
assertion in the same cycle as an ACK wins.

Timer interrupt service sequence:
1. `sw 1 -> 0x224` (enable source 0), `sw cmp -> 0x214`.
2. On `irq` (or polling `0x220`/`0x22C`): `sw 1 -> 0x21C` (clear timer flag),
   then `sw 1 -> 0x228` (ACK source 0).

### 3.3 UART / GPIO (planned full layout)
The as-built UART is TX-only at `0x200` and GPIO is OUT-only at `0x204`.
Planned richer layout (STATUS/CONTROL, IN/DIR) is deferred.

## 4. Cache and bus visibility

- Instruction fetches go through the I-cache.
- Loads and stores go through the D-cache.
- Cache refills and write-through traffic appear on the interconnect as ordinary memory transactions.
- The interconnect address decoder is the single source of truth for region routing.

## 5. Verification

- Every address region must be documented before RTL integration.
- Conflicting or overlapping ranges are not permitted.
- The linker script, boot ROM image, and RTL address decoder must agree.
- Tests: `tb/soc/run.sh` (irq_ctrl unit test, timer→irq test, soc_top
  decode/timer-irq/bus-error test).

## 6. CPU interrupt hookup (not yet implemented)

`single_cycle_cpu` / the pipeline have no CSR or trap support, so `soc_top`
only exposes `irq` as an output. To take interrupts the CPU needs:
- An `irq` input (machine external interrupt, mip.MEIP = `irq`).
- CSRs `mstatus` (MIE/MPIE), `mie` (MEIE), `mip`, `mtvec`, `mepc`, `mcause`
  and the `csrrw/csrrs/csrrc[i]` instructions (SYSTEM opcode is currently
  decoded as a no-op).
- Trap entry when `mstatus.MIE && mie.MEIE && irq`: `mepc <= pc` of the next
  un-retired instruction, `mcause <= 0x8000_000B`, `MPIE <= MIE`, `MIE <= 0`,
  `pc <= mtvec`; in the pipeline, flush younger stages first.
- `mret`: `pc <= mepc`, `MIE <= MPIE`.
- Export `mem_read` on the data port (`soc_top` currently infers loads from the
  opcode to flag unmapped reads) and optionally take `bus_err` as a load/store
  access-fault exception.

