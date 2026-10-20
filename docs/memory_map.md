# Memory Map

**Status:** Phase 0 — design freeze; §1/§3 updated with as-built SoC map (timer + IRQ controller, UART, main RAM)  
**Reset PC:** `0x0000_0000`  
**Date:** 2026-10-20

## 1. Address regions (as built — `rtl/soc/soc_core_top.sv`, `rtl/soc/soc_top.sv`)

The address map is defined once in `rtl/soc/soc_map_pkg.sv` and decoded by
`rtl/soc/addr_decode.sv` (the single source of truth for region routing).
Everything lives in the low 4 KiB so programs can reach every register with
`x0 + imm12` (e.g. `sw x1, 0x200(x0)`). ROM/SRAM/UART/GPIO/DONE addresses are
unchanged from `soc.sv`; Timer and IRQ controller are new. The UART register
block (`0x230`) and the 64 KiB main RAM (`0x0001_0000`, for C programs) were
added for software bring-up; every older address is unchanged. Both SoC tops
use the same map: `soc_top` (single-cycle CPU, no interrupts) and
`soc_core_top` (integrated pipelined core with I-/D-cache + priv unit; ROM+SRAM below
`0x200` are cacheable, peripherals are uncached). In `soc_core_top` the
irq controller output drives the core's machine external interrupt (§6).

| Address range               | Block          | Size      | Access     | Notes                                         |
|-----------------------------|----------------|-----------|------------|-----------------------------------------------|
| `0x0000_0000`–`0x0000_00FF` | Boot ROM       | 256 B (64 words) | Read-only | Reset vector; instruction fetch + data reads. Writes are ignored and set `bus_err` |
| `0x0000_0100`–`0x0000_01FF` | SRAM           | 256 B (64 words) | Read/write | Data memory                              |
| `0x0000_0200`               | UART TX alias  | 1 word    | Write-only | Legacy: low byte pushed into the UART TX FIFO (= UART DATA write); reads return 0 and never pop RX |
| `0x0000_0204`               | GPIO OUT       | 1 word    | Read/write | Low byte drives `gpio_out`                     |
| `0x0000_0208`               | DONE           | 1 word    | Read/write | Any write sets `done` (sim end flag); read = `done` |
| `0x0000_020C`               | —              | —         | —          | Unmapped (reserved)                           |
| `0x0000_0210`–`0x0000_021F` | Timer          | 4 words   | Read/write | See §3.1; irq source 0                         |
| `0x0000_0220`–`0x0000_022F` | IRQ controller | 4 words   | Read/write | See §3.2; drives SoC `irq` output              |
| `0x0000_0230`–`0x0000_023F` | UART           | 4 words   | Read/write | See §3.3; serial `uart_tx`/`uart_rx` (8N1)     |
| `0x0001_0000`–`0x0001_FFFF` | Main RAM       | 64 KiB    | R/W/X      | Code + data + stack for C programs; preloaded with `$readmemh`; uncached (`soc_core_top` only) |
| everything else             | unmapped       | —         | —          | Reads return `0x0000_0000`; sets `bus_err`    |

**Unmapped access handling.** A load or store to an unmapped address, or a
store to ROM, returns `0x0000_0000` (loads) / is dropped (stores) and sets the
sticky `bus_err` output of `soc_top`; `bus_err_addr` captures the address of
the first error. Both are cleared only by reset. (The CPU does not yet take a
bus-error exception; see §6.)

`soc_top` (legacy single-cycle SoC) implements neither the UART block nor main
RAM; it treats `0x230`–`0x23F` and `0x0001_0000`+ as unmapped.

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

- Reset PC (`core_top`) = `0x0000_0000` = Boot ROM word 0 (`RESET_VECTOR` in
  `soc_map_pkg.sv` documents it; the core hard-wires it).
- `soc_core_top` image loading (`$readmemh`, one 32-bit hex word per line):

  | Image        | Parameter  | Plusarg (overrides) | Word 0 lands at | Max size |
  |--------------|------------|---------------------|-----------------|----------|
  | Boot ROM     | `ROM_FILE` | `+ROM_HEX=<file>`   | `0x0000_0000`   | 64 words |
  | Main RAM     | `MEM_FILE` | `+MEM_HEX=<file>`   | `0x0001_0000`   | 16384 words |

- If a main-RAM image is given and no ROM image, the Boot ROM is filled with a
  two-instruction stub at the reset vector that jumps to main RAM:
  `0x000: lui t0, 0x10` / `0x004: jalr x0, 0(t0)` (all other ROM words NOP).
  A ROM image, when given, replaces the stub (old tests load ROM-only images
  and behave exactly as before).
- Instruction fetch is served from the Boot ROM and from main RAM; any other
  fetch address returns a NOP.
- C programs (`sw/nginx_lite`) are linked at `0x0001_0000` (crt0 first), use
  main RAM for `.text/.rodata/.data/.bss`, and put the stack at the top of RAM
  (`sp = 0x0002_0000`, grows down). `.data` needs no copy (the image is
  loaded into RAM); crt0 zeroes `.bss`.
- Main RAM is outside the D-cache range (`CACHE_LIMIT = 0x200`), so all its
  loads/stores go straight to the bus (correct, not fast).

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

### 3.3 UART (`0x0000_0230`, `rtl/soc/uart.sv`)
8N1 serial: line idles high, start bit 0, 8 data bits LSB first, stop bit 1.
Bit time = `BAUDDIV` clocks. 16-entry TX FIFO and 16-entry RX FIFO.
`soc_core_top` ports: `uart_tx` (out), `uart_rx` (in, defaults to idle 1 if
unconnected); `uart_byte`/`uart_valid` remain as a simulation tap that pulses
when a byte is accepted into the TX FIFO.

| Offset | Address | Register | Access | Reset | Description |
|--------|---------|----------|--------|-------|-------------|
| 0x0    | `0x230` | DATA     | W      | —     | Push byte `[7:0]` into the TX FIFO. If the FIFO is full the byte is dropped and `TX_OVERFLOW` is set (poll `TX_READY` first). |
|        |         |          | R      | —     | Pop the RX FIFO: `{23'b0, valid[8], byte[7:0]}`; returns 0 (valid = 0) and pops nothing when empty. |
| 0x4    | `0x234` | STATUS   | R      | `0x3` | bit0 `TX_READY` (TX FIFO not full), bit1 `TX_IDLE` (FIFO empty and shifter idle), bit2 `RX_VALID` (RX FIFO not empty), bit3 `RX_OVERRUN` (sticky: byte arrived with RX FIFO full), bit4 `TX_OVERFLOW` (sticky: DATA write with TX FIFO full) |
|        |         |          | W1C    |       | write 1 to bit3 / bit4 to clear |
| 0x8    | `0x238` | BAUDDIV  | R/W    | `UART_DIV` param (16) | clocks per bit; values < 4 act (and read back) as 4 |
| 0xC    | `0x23C` | —        | —      | —     | reserved, reads 0 |

Polled driver: `putc` = wait `STATUS.TX_READY`, write DATA; `getc` = read
DATA until bit 8 is set; before signalling DONE wait for `STATUS.TX_IDLE`.
The RX pop side effect relies on the core issuing exactly one `dmem_re`
cycle per uncached load (true for `core_top`).

GPIO is OUT-only at `0x204` (planned IN/DIR registers deferred).

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
  decode/timer-irq/bus-error test, UART unit test, `soc_sw_tb`: the C
  program `sw/nginx_lite` on `soc_core_top` talking over the serial UART, and
  `soc_timer_irq_tb`: timer interrupt taken by the integrated core through
  MEI, handler + mret, no re-entry).

## 6. CPU interrupt hookup (machine external interrupt)

`soc_top` (single-cycle CPU) has no trap support and only exposes `irq` as an
output. `soc_core_top` connects it to the integrated core:

```
timer.STATUS[0] (match) --src[0]--> irq_ctrl PENDING[0] & ENABLE[0]
    --> irq_ctrl.irq --> soc_core_top.irq --> core_top.meip
    --> csr_file mip.MEIP (bit 11) --> priv_unit: trap if mstatus.MIE && mie.MEIE
```

- `core_top` ports `meip` = `irq_ctrl.irq`; `mtip` and `msip` are tied to 0
  (the timer is delivered as an *external* interrupt, not as MTI/CLINT).
- The interrupt is taken at an instruction boundary in EX (commit point):
  `mepc` = pc of the not-yet-executed instruction, `mcause = 0x8000_000B`,
  `MPIE <= MIE`, `MIE <= 0`, pc <= `mtvec` (`mtvec[0]=1` vectored: base +
  4*11). `mret` restores `MIE <= MPIE` and returns to `mepc`.
- Masking: three levels — irq_ctrl `ENABLE[0]` (per source), `mie.MEIE`
  (bit 11, `0x800`), `mstatus.MIE` (bit 3).

Software sequence (as in `tb/soc/gen_timer_irq_prog.py`):

```
setup:   csrw mtvec, handler
         li   t0, 0x800 ; csrs mie, t0        # MEIE
         csrsi mstatus, 8                      # MIE
         sw   1,   0x224(x0)                   # irq_ctrl ENABLE[0] (timer)
         lw   t1,  0x210(x0) ; addi t1, t1, N
         sw   t1,  0x214(x0)                   # timer COMPARE = COUNT + N
handler: csrr t2, mcause                       # 0x8000000B
         sw   1,   0x21C(x0)                   # timer STATUS W1C  (clear source first)
         sw   1,   0x228(x0)                   # irq_ctrl ACK[0]
         mret
```

Clearing the timer flag before the ACK matters: sources are level-sensitive,
so ACKing while `STATUS[0]` is still set re-pends immediately and the handler
re-enters forever (the test checks `irq` is low at every `mret`).

Remaining gaps: no CLINT-style `mtime/mtimecmp` (MTI unused), `bus_err` is
not reported as an access-fault exception.
