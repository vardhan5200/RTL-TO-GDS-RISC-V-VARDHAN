# nginx-lite for soc_core_top. Produces nginx_lite.hex for $readmemh into
# main RAM (0x0001_0000): tb/soc/soc_sw_tb.sv loads it via MEM_FILE / +MEM_HEX.
# The core implements RV32I + Zicsr + MUL/DIV/DIVU/REM/REMU but not MULH*,
# so build for plain rv32i (GCC may emit mulh for divide-by-constant).
CROSS   ?= riscv64-unknown-elf-
CC      := $(CROSS)gcc
OBJCOPY := $(CROSS)objcopy
OBJDUMP := $(CROSS)objdump
SIZE    := $(CROSS)size
ARCH    := -march=rv32i_zicsr -mabi=ilp32
CFLAGS  := $(ARCH) -Os -ffreestanding -fno-builtin -nostdlib -msmall-data-limit=0 \
           -Wall -Wextra -ffunction-sections -fdata-sections
LDFLAGS := $(ARCH) -nostdlib -nostartfiles -T link.ld -Wl,--gc-sections -Wl,--no-relax
SRCS    := crt0.S main.c uart.c libc_min.c

all: nginx_lite.hex nginx_lite.dis

nginx_lite.elf: $(SRCS) soc.h uart.h link.ld
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $(SRCS) -lgcc
	$(SIZE) $@

nginx_lite.bin: nginx_lite.elf
	$(OBJCOPY) -O binary --only-section=.text --only-section=.rodata --only-section=.data $< $@

nginx_lite.hex: nginx_lite.bin bin2hex.py
	python3 bin2hex.py $< $@

nginx_lite.dis: nginx_lite.elf
	$(OBJDUMP) -d $< > $@

clean:
	rm -f nginx_lite.elf nginx_lite.bin nginx_lite.dis

.PHONY: all clean
