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
divu = lambda rd, rs1, rs2: r(1, rs2, rs1, 5, rd, 0x33)
rem  = lambda rd, rs1, rs2: r(1, rs2, rs1, 6, rd, 0x33)
remu = lambda rd, rs1, rs2: r(1, rs2, rs1, 7, rd, 0x33)
mulh = lambda rd, rs1, rs2: r(1, rs2, rs1, 1, rd, 0x33)
add  = lambda rd, rs1, rs2: r(0, rs2, rs1, 0, rd, 0x33)
lui  = lambda rd, imm20: ((imm20 & 0xfffff)<<12)|(rd<<7)|0x37
csrrw  = lambda rd, csr, rs1: i(csr, rs1, 1, rd, 0x73)
csrrs  = lambda rd, csr, rs1: i(csr, rs1, 2, rd, 0x73)
csrrsi = lambda rd, csr, uimm: i(csr, uimm, 6, rd, 0x73)
ECALL, MRET = 0x00000073, 0x30200073
MSTATUS, MISA, MIE, MTVEC, MSCRATCH, MEPC, MCAUSE, MTVAL = 0x300, 0x301, 0x304, 0x305, 0x340, 0x341, 0x342, 0x343

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
   mulh(27, 1, 2),               # 21: MULH not implemented -> illegal (cause 2)
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
MMU_H = 32                        # handler word index
mmu = [
    addi(8, 0, MMU_H * 4),
    csrrw(0, MTVEC, 8),           # page faults now trap -> handler skips the load
    lui(1, 0x400),                # x1 = 0x0040_0000
    addi(2, 0, 0x55),
    sw(2, 1, 0x100),              # VA 0x400100 -> PA 0x100
    lw(3, 1, 0x100),              # 0x55 (via MMU + D-cache)
    lw(4, 1, 0x104),              # preset 0x1234
    lui(5, 0x800),
    lw(6, 5, 0),                  # page fault -> trap (mcause 13), x6 stays 0
    addi(7, 0, 1),                # runs after mret (handler skips the load)
    jal(0, 0),
]
mmu += [0x00000013] * (MMU_H - len(mmu))
mmu += [
    csrrs(9, MCAUSE, 0),          # x9 = mcause
    csrrs(10, MEPC, 0),
    addi(10, 10, 4),
    csrrw(0, MEPC, 10),
    MRET,
]
out2 = os.path.join(os.path.dirname(os.path.abspath(__file__)), "core_mmu_prog.hex")
with open(out2, "w") as f:
    for k in range(64):
        f.write("%08x\n" % (mmu[k] if k < len(mmu) else 0x00000013))
print("wrote", out2)

# ---- DIV/DIVU/REM/REMU test (core_div_tb.sv, flat memory) ----
divp = [
    addi(1, 0, 20), addi(2, 0, 3),
    div(3, 1, 2),                 # 2: 20/3 = 6 (RAW on x1/x2 right behind the addis)
    add(4, 3, 1),                 # 3: back-to-back dependent ADD: 26
    divu(5, 1, 2),                # 4: 6
    rem(6, 1, 2),                 # 5: 2
    remu(7, 1, 2),                # 6: 2
    addi(8, 0, -20),              # 7
    div(9, 8, 2),                 # 8: -6
    rem(10, 8, 2),                # 9: -2
    divu(11, 8, 2),               # 10: 0xFFFFFFEC/3
    remu(12, 8, 2),               # 11
    div(13, 1, 0),                # 12: x/0 -> -1
    rem(14, 1, 0),                # 13: x/0 rem -> 20
    divu(15, 8, 0),               # 14: 0xFFFFFFFF
    remu(16, 8, 0),               # 15: -20
    lui(17, 0x80000),             # 16: INT_MIN
    addi(18, 0, -1),              # 17
    div(19, 17, 18),              # 18: INT_MIN/-1 -> INT_MIN
    rem(20, 17, 18),              # 19: 0
    div(21, 1, 2),                # 20: 6
    b(8, 3, 21, 0),               # 21: beq x21, x3, +8 (taken, uses DIV result)
    addi(22, 0, 99),              # 22: skipped
    addi(23, 0, 1),               # 23
    addi(24, 0, 0x100),           # 24
    sw(1, 24, 0),                 # 25: mem[0x100] = 20
    div(25, 1, 2),                # 26: 6
    lw(26, 24, 0),                # 27: load right after DIV: 20
    add(27, 26, 25),              # 28: 26
    sw(25, 24, 4),                # 29: store DIV result
    lw(28, 24, 4),                # 30: 6
    div(29, 1, 2),                # 31: 6
    div(30, 29, 2),               # 32: DIV->DIV dependent: 2
    addi(31, 0, 1),               # 33: done flag
    jal(0, 0),                    # 34
]
out3 = os.path.join(os.path.dirname(os.path.abspath(__file__)), "core_div_prog.hex")
with open(out3, "w") as f:
    for k in range(64):
        f.write("%08x\n" % (divp[k] if k < len(divp) else 0x00000013))
print("wrote", out3)

# ---- MMU page-fault trap test (core_pf_tb.sv, flat memory, USE_MMU=1) ----
# satp root PA 0x2000. L1[1]: VA 0x0040_0000 -> PA 0 RW megapage; L1[2]: invalid
# (VA 0x0080_0000); L1[3]: VA 0x00C0_0000 -> PA 0 read-only megapage;
# L1[4]: pointer to L0 at PA 0x3000 whose entry 5 (VA 0x0100_5000) is invalid.
PF_H = 64
pf = []
pf_pc = {}
def P(w, tag=None):
    if tag: pf_pc[tag] = 4 * len(pf)
    pf.append(w)
P(addi(1, 0, PF_H * 4)); P(csrrw(0, MTVEC, 1))
P(lui(31, 0x400)); P(addi(31, 31, 0x300))     # trap log pointer: VA 0x400300 (PA 0x300)
P(lui(2, 0x400))                              # RW megapage
P(lui(3, 0x800))                              # unmapped
P(lui(4, 0xC00))                              # read-only megapage
P(lui(5, 0x1005))                             # two-level walk, invalid leaf
P(addi(10, 0, 0x5A5)); P(addi(13, 0, 0x5A5))  # sentinels for faulting load rds
P(addi(11, 0, 0x77))
P(lw(10, 3, 0x24), "ld")                      # load page fault: VA 0x800024 -> 13
P(addi(20, 20, 1))                            # must run exactly once after mret
P(sw(11, 4, 0x180), "st")                     # store page fault: VA 0xC00180 (R only) -> 15
P(addi(20, 20, 1))
P(lw(12, 4, 0x180))                           # load through the R-only page works: PA 0x180
P(lb(13, 5, 7), "ld2")                        # two-level walk, invalid L0 PTE -> 13
P(addi(20, 20, 1))
P(sw(11, 2, 0x184))                           # normal store still works: PA 0x184 = 0x77
P(lui(22, 0xC0DE5)); P(addi(22, 22, 0x00D))   # signature 0xC0DE500D
P(sw(22, 2, 0x3F0))                           # PA 0x3F0 = signature (after all traps)
P(jal(0, 0))
assert len(pf) <= PF_H
pf += [0x00000013] * (PF_H - len(pf))
pf += [
    csrrs(25, MCAUSE, 0),
    csrrs(26, MTVAL, 0),
    csrrs(27, MEPC, 0),
    sw(25, 31, 0), sw(26, 31, 4), sw(27, 31, 8),   # log {mcause, mtval, mepc}
    addi(31, 31, 12),
    addi(27, 27, 4), csrrw(0, MEPC, 27),           # skip the faulting instruction
    addi(24, 24, 1),                               # trap count
    MRET,
]
out4 = os.path.join(os.path.dirname(os.path.abspath(__file__)), "core_pf_prog.hex")
with open(out4, "w") as f:
    for k in range(128):
        f.write("%08x\n" % (pf[k] if k < len(pf) else 0x00000013))
print("wrote", out4, "fault pcs:", {k: hex(v) for k, v in pf_pc.items()})
