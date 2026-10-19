#!/usr/bin/env python3
"""Program for tb/soc/soc_timer_irq_tb.sv (soc_core_top, integrated core).
Writes tb/soc/soc_timer_irq_prog.hex (64 words, $readmemh).

Flow:
  A) mtvec = handler, mie.MEIE = 1, mstatus.MIE = 1, but irq_ctrl ENABLE = 0.
     Timer COMPARE = COUNT + 10. Poll IRQ PENDING until the timer pends:
     the controller masks it, so no trap may happen (x30 = handler count = 0).
  B) irq_ctrl ENABLE[0] = 1 -> irq -> meip -> trap (mcause 0x8000000B).
     Handler: count++, save mcause/mepc, TIMER STATUS W1C, IRQ ACK, mret.
  C) Re-arm COMPARE = COUNT + 15, wait for the 2nd interrupt, then run a
     20-iteration delay loop (no re-entry allowed), store results, DONE.
"""
import os

def i(imm, rs1, f3, rd, op): return ((imm & 0xfff) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op
def s(imm, rs2, rs1, f3):
    imm &= 0xfff
    return ((imm >> 5) << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | ((imm & 0x1f) << 7) | 0x23
def b(off, rs2, rs1, f3):
    o = off & 0x1fff
    return (((o >> 12) & 1) << 31) | (((o >> 5) & 0x3f) << 25) | (rs2 << 20) | (rs1 << 15) | \
           (f3 << 12) | (((o >> 1) & 0xf) << 8) | (((o >> 11) & 1) << 7) | 0x63
addi   = lambda rd, rs1, imm: i(imm, rs1, 0, rd, 0x13)
lw     = lambda rd, rs1, imm: i(imm, rs1, 2, rd, 0x03)
sw     = lambda rs2, rs1, imm: s(imm, rs2, rs1, 2)
beq    = lambda rs1, rs2, off: b(off, rs2, rs1, 0)
bne    = lambda rs1, rs2, off: b(off, rs2, rs1, 1)
bge    = lambda rs1, rs2, off: b(off, rs2, rs1, 5)
lui    = lambda rd, imm20: ((imm20 & 0xfffff) << 12) | (rd << 7) | 0x37
csrrw  = lambda rd, csr, rs1: i(csr, rs1, 1, rd, 0x73)
csrrs  = lambda rd, csr, rs1: i(csr, rs1, 2, rd, 0x73)
csrrsi = lambda rd, csr, uimm: i(csr, uimm, 6, rd, 0x73)
JSELF, MRET = 0x0000006F, 0x30200073
MSTATUS, MIE, MTVEC, MEPC, MCAUSE = 0x300, 0x304, 0x305, 0x341, 0x342
# x15 = timer base 0x210: COUNT +0, COMPARE +4, STATUS +0xC,
#       irq_ctrl PENDING +0x10, ENABLE +0x14, ACK +0x18, CLAIM +0x1C
HANDLER = 40
main = [
    addi(11, 0, HANDLER * 4), csrrw(0, MTVEC, 11),   # 0,1  mtvec = handler (direct)
    addi(15, 0, 0x210),                              # 2    timer / irq_ctrl base
    addi(17, 0, 1),                                  # 3
    lui(18, 1), addi(18, 18, -2048),                 # 4,5  x18 = 0x800 (MEIE)
    csrrs(0, MIE, 18),                               # 6    mie.MEIE = 1
    csrrsi(0, MSTATUS, 8),                           # 7    mstatus.MIE = 1
    # A) timer pends while the controller masks it
    lw(16, 15, 0), addi(16, 16, 10), sw(16, 15, 4),  # 8-10 COMPARE = COUNT + 10
    lw(19, 15, 0x10), beq(19, 0, -4),                # 11,12 poll IRQ PENDING
    addi(30, 22, 0),                                 # 13   handler count while masked (0)
    # B) unmask in the controller -> MEI trap
    sw(17, 15, 0x14),                                # 14   IRQ ENABLE = 1
    beq(22, 0, 0),                                   # 15   wait for handler (x22 != 0)
    addi(31, 26, 0),                                 # 16   mcause of 1st irq
    # C) second interrupt, then make sure it does not re-enter
    lw(16, 15, 0), addi(16, 16, 15), sw(16, 15, 4),  # 17-19 COMPARE = COUNT + 15
    addi(6, 0, 2), bne(22, 6, 0),                    # 20,21 wait for count == 2
    addi(7, 0, 20), addi(7, 7, -1), bne(7, 0, -4),   # 22-24 delay loop
    csrrs(28, MSTATUS, 0),                           # 25   MIE restored by mret
    lw(29, 15, 0x10),                                # 26   PENDING at end (0)
    sw(22, 0, 0x100), sw(26, 0, 0x104), sw(27, 0, 0x108),  # 27-29 SRAM log
    sw(17, 0, 0x208),                                # 30   DONE
    JSELF,                                           # 31
]
handler = [
    csrrs(20, MCAUSE, 0),                            # 40
    bge(20, 0, 4 * 9),                               # 41   not an interrupt -> exc path
    csrrs(27, MEPC, 0),                              # 42
    addi(22, 22, 1),                                 # 43   irq count
    addi(26, 20, 0),                                 # 44   save mcause
    addi(25, 0, 1),                                  # 45
    sw(25, 15, 0xC),                                 # 46   TIMER STATUS W1C (clear source)
    sw(25, 15, 0x18),                                # 47   IRQ ACK source 0
    MRET,                                            # 48
    JSELF,                                           # 49   (unused)
    addi(23, 23, 1), JSELF,                          # 50,51 unexpected exception: count, hang
]
assert len(main) <= HANDLER
prog = main + [0x13] * (HANDLER - len(main)) + handler
assert len(prog) <= 64
out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "soc_timer_irq_prog.hex")
with open(out, "w") as f:
    for k in range(64):
        f.write("%08x\n" % (prog[k] if k < len(prog) else 0x13))
print("wrote", out)
