# demo — firmware for rtl/peripherals/demo_soc.sv

Banner, 7-seg count 0..3, 4x4 matmul on the accelerator, then a UART command
shell (`PING`, `SEG <h>`, `MAT`, `QUIT`; anything else -> `ERR`).
Shares crt0.S, link.ld, the UART driver, libc_min.c and bin2hex.py with
`sw/nginx_lite`. `demo.hex` is committed. Build: `make -C sw/demo`
(1584 B text+rodata, 32 B bss). Details and protocol: `docs/demo_soc.md`.
Run: `make demo`.
