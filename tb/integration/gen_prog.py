#!/usr/bin/env python3
"""Tiny RV32 assembler for the core integration test program.
Writes tb/integration/core_prog.hex (one 32-bit word per line, $readmemh)."""
import os

def r(f7, rs2, rs1, f3, rd, op): return (f7<<25)|(rs2<<20)|(rs1<<15)|(f3<<12)|(rd<<7)|op
def i(imm, rs1, f3, rd, op):     return ((imm & 0xfff)<<20)|(rs1<<15)|(f3<<12)|(rd<<7)|op
def s(imm, rs2, rs1, f3):
    imm &= 0xfff
    return ((imm>>5)<<25)|(rs2<<20)|(rs1<<15)|(f3<<12)|((imm&0x1f)<<7)|0x23
def b(off, rs2, rs1, f3):
    o = off & 0x1fff
    return (((o>>12)&1)<<31)|(((o>>5)&0x3f)<<25)|(rs2<<20)|(rs1<<15)|(f3<<12)|(((o>>1)&0xf)<<8)|(((o>>11)&1)<<7)|0x63
def jal(off, rd):
    o = off & 0x1fffff
    return (((o>>20)&1)<<31)|(((o>>1)&0x3ff)<<21)|(((o>>11)&1)<<20)|(((o>>12)&0xff)<<12)|(rd<<7)|0x6f
addi = lambda rd, rs1, imm: i(imm, rs1, 0, rd, 0x13)
lw   = lambda rd, rs1, imm: i(imm, rs1, 2, rd, 0x03)
lb   = lambda rd, rs1, imm: i(imm, rs1, 0, rd, 0x03)
lbu  = lambda rd, rs1, imm: i(imm, rs1, 4, rd, 0x03)
sw   = lambda rs2, rs1, imm: s(imm, rs2, rs1, 2)
sb   = lambda rs2, rs1, imm: s(imm, rs2, rs1, 0)
mul  = lambda rd, rs1, rs2: r(1, rs2, rs1, 0, rd, 0x33)
div  = lambda rd, rs1, rs2: r(1, rs2, rs1, 4, rd, 0x33)
add  = lambda rd, rs1, rs2: r(0, rs2, rs1, 0, rd, 0x33)
lui  = lambda rd, imm20: ((imm20 & 0xfffff)<<12)|(rd<<7)|0x37
csrrw  = lambda rd, csr, rs1: i(csr, rs1, 1, rd, 0x73)
csrrs  = lambda rd, csr, rs1: i(csr, rs1, 2, rd, 0x73)
csrrsi = lambda rd, csr, uimm: i(csr, uimm, 6, rd, 0x73)
ECALL, MRET = 0x00000073, 0x30200073
MSTATUS, MISA, MIE, MTVEC, MSCRATCH, MEPC, MCAUSE = 0x300, 0x301, 0x304, 0x305, 0x340, 0x341, 0x342

HANDLER = 40 * 4
prog = {}
def at(idx, *words):
    for k, w in enumerate(words): prog[idx + k] = w

at(0,
   addi(1, 0, 6), addi(2, 0, 7),
   mul(3, 1, 2),                 # 2: x3 = 42
   addi(4, 3, 1),                # 3: x4 = 43 (RAW on MUL)
   addi(5, 0, 0x100),            # 4: SRAM base (cacheable)
   sw(3, 5, 0),                  # 5: SRAM[0] = 42 (write-through, no allocate)
   lw(6, 5, 0),                  # 6: D-cache miss -> refill -> 42
   addi(6, 6, 1),                # 7: x6 = 43 (load-use)
   sw(6, 5, 4),                  # 8: store hit: cache word updated
   lw(7, 5, 4),                  # 9: D-cache hit -> 43
   addi(8, 0, 0xAB),             # 10
   sb(8, 5, 9),                  # 11: byte store
   lbu(9, 5, 9),                 # 12: 0x000000AB (hit)
   lb(10, 5, 9),                 # 13: 0xFFFFFFAB
   addi(11, 0, HANDLER),         # 14
   csrrw(0, MTVEC, 11),          # 15
   csrrs(12, MISA, 0),           # 16: 0x40001100
   csrrw(0, MSCRATCH, 1),        # 17
   csrrs(13, MSCRATCH, 0),       # 18: 6
   ECALL,                        # 19: trap cause 11
   addi(14, 0, 1),               # 20: runs after mret
   div(27, 1, 2),                # 21: DIV not implemented -> illegal (cause 2)
   addi(15, 0, 0x210),           # 22: timer base
   lw(16, 15, 0),                # 23: COUNT (uncached MMIO)
   addi(16, 16, 40),             # 24
   sw(16, 15, 4),                # 25: COMPARE = COUNT + 40
   addi(17, 0, 1),               # 26
   sw(17, 15, 0x14),             # 27: IRQ_ENABLE(0x224) = 1 (timer)
   lui(18, 1), addi(18, 18, -2048),  # 28,29: x18 = 0x800 (MEIE)
   csrrs(0, MIE, 18),            # 30
   csrrsi(0, MSTATUS, 8),        # 31: mstatus.MIE = 1
   b(0, 0, 22, 0),               # 32: wait: beq x22, x0, wait
   addi(23, 0, 0x208),           # 33
   sw(1, 23, 0),                 # 34: DONE
   jal(0, 0),                    # 35: spin
)
H = HANDLER // 4
at(H,
   csrrs(20, MCAUSE, 0),         # mcause
   b(4 * 7, 0, 20, 4),           # blt x20, x0, irq (+7 words)
   csrrs(24, MEPC, 0),
   addi(24, 24, 4),
   csrrw(0, MEPC, 24),
   addi(21, 21, 1),              # exception count
   add(28, 28, 20),              # sum of exception causes
   MRET,
   # irq:
   addi(25, 0, 1),
   sw(25, 15, 0xC),              # TIMER_STATUS W1C (clear source first)
   sw(25, 15, 0x18),             # IRQ_ACK(0x228)
   addi(22, 0, 1),
   addi(26, 20, 0),              # save interrupt cause
   MRET,
)
assert max(prog) < 64, "program exceeds 64-word ROM"
out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "core_prog.hex")
with open(out, "w") as f:
    for k in range(64):
        f.write("%08x\n" % prog.get(k, 0x00000013))
print("wrote", out)

# ---- D-side Sv32 translation test (core_mmu_tb.sv, flat memory) ----
# VA 0x0040_0000 megapage -> PA 0x0 (root table at PA 0x2000); VA 0x0080_0000 unmapped.
mmu = [
    lui(1, 0x400),                # x1 = 0x0040_0000
    addi(2, 0, 0x55),
    sw(2, 1, 0x100),              # VA 0x400100 -> PA 0x100
    lw(3, 1, 0x100),              # 0x55 (via MMU + D-cache)
    lw(4, 1, 0x104),              # preset 0x1234
    lui(5, 0x800),
    lw(6, 5, 0),                  # page fault -> squashed, x6 stays 0
    addi(7, 0, 1),                # still executes
    jal(0, 0),
]
out2 = os.path.join(os.path.dirname(os.path.abspath(__file__)), "core_mmu_prog.hex")
with open(out2, "w") as f:
    for k in range(64):
        f.write("%08x\n" % (mmu[k] if k < len(mmu) else 0x00000013))
print("wrote", out2)
