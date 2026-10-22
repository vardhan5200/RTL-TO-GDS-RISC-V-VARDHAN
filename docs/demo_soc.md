# Demo SoC (simulation "FPGA demo")

`rtl/peripherals/demo_soc.sv` combines the integrated pipelined core
(`rtl/core/core_top.sv`, the same configuration `soc_core_top` uses and the one
already running C programs: nginx-lite) with:

- the existing UART (`rtl/soc/uart.sv`, reused as-is; 8N1, FIFOs),
- a single-digit 7-segment display (`rtl/peripherals/seven_seg.sv`, `0x240`),
- a 4x4 signed matrix-multiply accelerator (`rtl/peripherals/matmul4x4.sv`, `0x400`),
- Boot ROM stub, 64 KiB main RAM (program image), GPIO and DONE as in `soc_core_top`.

The core was chosen over the single-cycle CPU because it is the CPU the
C-program flow (`sw/nginx_lite`: crt0, linker script, Boot ROM stub, main RAM
fetch) is already verified on; the single-cycle `soc_top` has no main RAM and
no UART block. Register maps: `docs/memory_map.md` §3.3–§3.5.

## Run

```bash
make demo            # 7-seg + matmul unit tests and the full demo transcript
make test            # includes the same tests (test-demo)
```

Needs only Icarus Verilog (`iverilog -g2012`, `vvp`). The firmware hex
`sw/demo/demo.hex` is committed; rebuild it with `make -C sw/demo`
(`riscv64-unknown-elf-gcc`, `-march=rv32i_zicsr -mabi=ilp32`; rv32i because the
core traps on MULH*).

## Firmware (`sw/demo/main.c`)

On boot:
1. prints `RISC-V demo SoC: 7-seg + UART + matmul4x4`
2. counts 0, 1, 2, 3 on the 7-segment display, prints `7SEG count 0..3 done`
3. loads A and B into the accelerator, starts it, polls DONE and prints
   `C = A x B:` plus the four rows of C (space-separated decimals)
4. prints `READY` and serves UART commands

## UART command protocol

One command per line, terminated by `\n` (`\r` is ignored), case-sensitive.
Every reply line ends in `\r\n`. No echo.

| Command   | Reply                                  | Effect |
|-----------|----------------------------------------|--------|
| `PING`    | `PONG`                                 | — |
| `SEG <h>` | `OK` (`ERR` if `h` is not one hex digit 0–9/A–F/a–f) | 7-seg shows `h` |
| `MAT`     | 4 rows of C, then `OK`                 | reruns the accelerator on the loaded A, B |
| `QUIT`    | `BYE`                                  | firmware exits; crt0 waits for the UART to drain and sets DONE |
| anything else | `ERR`                              | — |

## Testbench (`tb/peripherals/demo_soc_tb.sv`)

Decodes the serial `uart_tx` pin (`[UART TX]`), sends `PING`, `SEG 7`, `MAT`,
`HELLO`, `SEG Z`, `QUIT` on the serial `uart_rx` pin (`[UART RX]`), decodes the
7-segment pins back to a digit on every write (`[7SEG] d`) and prints the
accelerator's C registers (`[MATMUL]`). It checks all 18 TX lines exactly
(matrix rows against a TB-computed reference), CRLF endings, the 7-seg
sequence `0 1 2 3 7`, A/B/C register contents, exit code, no bus error and no
UART overrun/overflow, and prints `DEMO SOC TEST: PASS`/`FAIL`.

Matrices used:

```
A = [   1    2    3    4 ]     B = [  1    0   -1    2 ]
    [   5    6    7    8 ]         [  0    1    2   -3 ]
    [  -1   -2   -3   -4 ]         [ -2    3    0    1 ]
    [ 100 -200  300 -400 ]         [ 10  -10    5 1000 ]

C = [    35    -29     23    3999 ]
    [    71    -53     47    7999 ]
    [   -35     29    -23   -3999 ]
    [ -4500   4700  -2500 -398900 ]
```

Unit tests: `tb/peripherals/seven_seg_tb.sv` (all 16 patterns decode back,
blank/dp, byte strobe, read-back) and `tb/peripherals/matmul4x4_tb.sv`
(mixed-sign, identity, ±32767/−32768 extremes, 5 random sets vs a TB reference;
BUSY/DONE/CYCLES; writes ignored while busy).
