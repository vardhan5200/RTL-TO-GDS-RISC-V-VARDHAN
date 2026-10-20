# sw/perf — microbenchmarks for soc_core_top. Produces perf.hex (committed),
# loaded into main RAM (0x0001_0000) by tb/perf/perf_tb.sv.
# Runtime (crt0, linker script, UART driver, memset/memcpy, bin2hex) is shared
# with sw/nginx_lite. C is plain rv32i_zicsr (+zifencei for fence.i; the core
# has no MULH*, which GCC may emit for divide-by-constant); the M-extension
# ops under test are only in bench.S (".option arch, +m").
CROSS   ?= riscv64-unknown-elf-
CC      := $(CROSS)gcc
OBJCOPY := $(CROSS)objcopy
OBJDUMP := $(CROSS)objdump
SIZE    := $(CROSS)size
RT      := ../nginx_lite
ARCH    := -march=rv32i_zicsr_zifencei -mabi=ilp32
CFLAGS  := $(ARCH) -Os -ffreestanding -fno-builtin -nostdlib -msmall-data-limit=0 \
           -Wall -Wextra -ffunction-sections -fdata-sections -I$(RT)
LDFLAGS := $(ARCH) -nostdlib -nostartfiles -T $(RT)/link.ld -Wl,--gc-sections -Wl,--no-relax
SRCS    := $(RT)/crt0.S main.c bench.S $(RT)/uart.c $(RT)/libc_min.c

all: perf.hex perf.dis

perf.elf: $(SRCS) $(RT)/soc.h $(RT)/uart.h $(RT)/link.ld
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $(SRCS) -lgcc
	$(SIZE) $@

perf.bin: perf.elf
	$(OBJCOPY) -O binary --only-section=.text --only-section=.rodata --only-section=.data $< $@

perf.hex: perf.bin $(RT)/bin2hex.py
	python3 $(RT)/bin2hex.py $< $@

perf.dis: perf.elf
	$(OBJDUMP) -d $< > $@

clean:
	rm -f perf.elf perf.bin perf.dis

.PHONY: all clean
