# demo_soc firmware. Produces demo.hex for $readmemh into main RAM
# (0x0001_0000); tb/peripherals/demo_soc_tb.sv loads it (MEM_FILE/+MEM_HEX).
# Reuses crt0.S, link.ld, the UART driver, libc_min.c and bin2hex.py from
# sw/nginx_lite. Plain rv32i: the core traps on MULH* (GCC can emit them).
CROSS   ?= riscv64-unknown-elf-
CC      := $(CROSS)gcc
OBJCOPY := $(CROSS)objcopy
OBJDUMP := $(CROSS)objdump
SIZE    := $(CROSS)size
COMMON  := ../nginx_lite
ARCH    := -march=rv32i_zicsr -mabi=ilp32
CFLAGS  := $(ARCH) -Os -ffreestanding -fno-builtin -nostdlib -msmall-data-limit=0 \
           --param=min-pagesize=0 -Wall -Wextra -ffunction-sections -fdata-sections -I. -I$(COMMON)
LDFLAGS := $(ARCH) -nostdlib -nostartfiles -T $(COMMON)/link.ld -Wl,--gc-sections -Wl,--no-relax -Wl,--no-warn-rwx-segments
SRCS    := $(COMMON)/crt0.S main.c $(COMMON)/uart.c $(COMMON)/libc_min.c

all: demo.hex demo.dis

demo.elf: $(SRCS) demo_soc.h $(COMMON)/soc.h $(COMMON)/uart.h $(COMMON)/link.ld
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $(SRCS) -lgcc
	$(SIZE) $@

demo.bin: demo.elf
	$(OBJCOPY) -O binary --only-section=.text --only-section=.rodata --only-section=.data $< $@

demo.hex: demo.bin $(COMMON)/bin2hex.py
	python3 $(COMMON)/bin2hex.py $< $@

demo.dis: demo.elf
	$(OBJDUMP) -d $< > $@

clean:
	rm -f demo.elf demo.bin demo.dis

.PHONY: all clean
