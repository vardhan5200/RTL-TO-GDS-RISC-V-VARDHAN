# nginx-lite — first C program for the SoC

A tiny freestanding C program for `rtl/soc/soc_core_top.sv` (integrated
RV32 core). It prints `Hello from RISC-V\r\n` on the UART, reads one HTTP
request line (plus headers up to the blank line) from UART RX, and answers:

- request line starts with `GET /` →
  `HTTP/1.0 200 OK\r\n\r\nHello from RISC-V nginx-lite\r\n`
- anything else → `HTTP/1.0 404 Not Found\r\n\r\n`

then waits for the UART to drain, writes the exit code to GPIO (`0x204`) and
sets DONE (`0x208`).

| File          | Purpose |
|---------------|---------|
| `crt0.S`      | `_start` at `0x0001_0000`: `mtvec` = trap catcher (exit code `0xEE`), `sp` = `0x0002_0000`, zero `.bss`, `call main`, GPIO = return value, wait TX idle, DONE |
| `link.ld`     | everything in main RAM (64 KiB @ `0x0001_0000`), stack at the top |
| `soc.h`       | register addresses (UART @ `0x230`, GPIO, DONE) |
| `uart.c/.h`   | polled `uart_putc/puts/getc/flush` |
| `libc_min.c`  | `memset`/`memcpy` (GCC may emit calls even when freestanding) |
| `main.c`      | the program |
| `bin2hex.py`  | raw binary → `$readmemh` words |
| `nginx_lite.hex` | **committed** build output, so the test runs without a toolchain |

## Build

```bash
sudo apt-get install gcc-riscv64-unknown-elf   # GCC 14.2, has rv32i/ilp32 multilib
make -C sw/nginx_lite                          # -> nginx_lite.hex (+ .elf, .dis)
```

Flags: `-march=rv32i_zicsr -mabi=ilp32 -Os -ffreestanding -nostdlib`.
The core implements MUL/DIV/DIVU/REM/REMU but not MULH/MULHSU/MULHU (they trap
as illegal), and GCC can emit `mulh` for division by a constant, so the build
uses plain `rv32i`; libgcc is linked for any multiply/divide helpers.
Current size: 615 bytes `.text+.rodata`, 128 bytes `.bss`.

## Run (simulation)

```bash
bash tb/soc/run.sh            # includes soc_sw_tb MODE=0 (GET) and MODE=1 (404)
```

`tb/soc/soc_sw_tb.sv` loads the hex as the main-RAM image (`MEM_FILE`, or
`+MEM_HEX=<file>` at `vvp` time). With no ROM image, the Boot ROM holds a
2-word stub at the reset vector (`lui t0,0x10; jalr x0,0(t0)`) that jumps to
`_start`. The testbench decodes the serial `uart_tx` line, sends the request on
`uart_rx` after the hello line, and compares the TX stream byte for byte.

Memory map and UART registers: `docs/memory_map.md` §1–§3.
