/* bench.S — timed microbenchmark kernels for sw/perf (rv32im_zicsr).
 *
 * Every kernel takes a0 = uint32_t *res and writes
 *   res[0] = mcycle delta, res[1] = minstret delta, res[2] = functional result.
 * The window is   csrr minstret; csrr mcycle; <body>; csrr mcycle; csrr minstret
 * so an empty body (k_empty) gives the fixed measurement overhead, which
 * main.c subtracts.  Kernels that the TB should probe (caches, loads/stores,
 * CPI loop) also bracket the window with GPIO marker stores
 *   GPIO(0x204) <- 0x5A000000 | perf_mark_id   (window open)
 *   GPIO(0x204) <- 0x5B000000 | perf_mark_id   (window close)
 * perf_mark_id is a global set by main.c before the call.
 * t5/t6 hold the start counters and must not be touched by a body.
 */
    .option arch, +m
    .text

.macro ENTER
    addi sp, sp, -64
    sw ra, 0(sp);  sw s0, 4(sp);  sw s1, 8(sp);  sw s2, 12(sp)
    sw s3, 16(sp); sw s4, 20(sp); sw s5, 24(sp); sw s6, 28(sp)
    sw s7, 32(sp); sw s8, 36(sp); sw s9, 40(sp); sw s10, 44(sp)
    sw s11, 48(sp)
.endm
.macro LEAVE
    lw ra, 0(sp);  lw s0, 4(sp);  lw s1, 8(sp);  lw s2, 12(sp)
    lw s3, 16(sp); lw s4, 20(sp); lw s5, 24(sp); lw s6, 28(sp)
    lw s7, 32(sp); lw s8, 36(sp); lw s9, 40(sp); lw s10, 44(sp)
    lw s11, 48(sp)
    addi sp, sp, 64
    ret
.endm
.macro MARK tag            /* GPIO <- tag<<24 | perf_mark_id */
    la   t0, perf_mark_id
    lw   t1, 0(t0)
    li   t0, (\tag << 24)
    or   t1, t1, t0
    li   t0, 0x204
    sw   t1, 0(t0)
.endm
.macro TSTART
    csrr t5, minstret
    csrr t6, mcycle
.endm
.macro TEND
    csrr t2, mcycle
    csrr t3, minstret
    sub  t2, t2, t6
    sub  t3, t3, t5
    sw   t2, 0(a0)
    sw   t3, 4(a0)
.endm

/* ---- overhead reference ---- */
    .globl k_empty
k_empty:
    TSTART
    TEND
    sw zero, 8(a0)
    ret

/* ---- 1. CPI loop: a1 = iterations (>0). 8 ALU ops + not-taken beq +
 *      addi + taken bne = 11 instructions per iteration. ---- */
    .globl k_cpi_loop
    .balign 16
k_cpi_loop:
    ENTER
    mv   s1, a1
    li   s0, 0
    MARK 0x5A
    TSTART
1:  add  s2, s0, s1
    xor  s3, s2, s1
    sub  s4, s3, s0
    or   s5, s4, s2
    and  s6, s5, s3
    slli s7, s6, 3
    srli s8, s7, 1
    add  s0, s0, s8
    beq  s1, zero, 2f        /* never taken (s1 > 0 here) */
2:  addi s1, s1, -1
    bnez s1, 1b
    TEND
    MARK 0x5B
    sw   s0, 8(a0)
    LEAVE

/* ---- 2a. I-cache: loop body that fits (16 addi + 2 = 72 B) ---- */
    .globl k_ic_small
    .balign 16
k_ic_small:
    ENTER
    mv   s1, a1
    li   s2, 0
    MARK 0x5A
    TSTART
    .balign 16
1:  .rept 16
    addi s2, s2, 1
    .endr
    addi s1, s1, -1
    bnez s1, 1b
    TEND
    MARK 0x5B
    sw   s2, 8(a0)
    LEAVE

/* ---- 2b. I-cache: loop body larger than the 128 B cache
 *      (64 addi + 2 = 264 B, sequential -> every line is evicted) ---- */
    .globl k_ic_big
    .balign 16
k_ic_big:
    ENTER
    mv   s1, a1
    li   s2, 0
    MARK 0x5A
    TSTART
    .balign 16
1:  .rept 64
    addi s2, s2, 1
    .endr
    addi s1, s1, -1
    bnez s1, 1b
    TEND
    MARK 0x5B
    sw   s2, 8(a0)
    LEAVE

/* ---- 2c/4. strided load sum: a1 = base, a2 = count (>0), a3 = stride (bytes) ---- */
    .globl k_ld_stride
    .balign 16
k_ld_stride:
    ENTER
    li   s0, 0
    MARK 0x5A
    TSTART
1:  lw   s2, 0(a1)
    add  s0, s0, s2
    add  a1, a1, a3
    addi a2, a2, -1
    bnez a2, 1b
    TEND
    MARK 0x5B
    sw   s0, 8(a0)
    LEAVE

/* ---- 4a. array sum, unrolled x4: a1 = base, a2 = words (multiple of 4, >0) ---- */
    .globl k_sum
    .balign 16
k_sum:
    ENTER
    li   s0, 0
    MARK 0x5A
    TSTART
1:  lw   s2, 0(a1)
    lw   s3, 4(a1)
    lw   s4, 8(a1)
    lw   s5, 12(a1)
    add  s0, s0, s2
    add  s0, s0, s3
    add  s0, s0, s4
    add  s0, s0, s5
    addi a1, a1, 16
    addi a2, a2, -4
    bnez a2, 1b
    TEND
    MARK 0x5B
    sw   s0, 8(a0)
    LEAVE

/* ---- 4b. array copy, unrolled x4: a1 = src, a2 = dst, a3 = words (multiple of 4, >0) ---- */
    .globl k_copy
    .balign 16
k_copy:
    ENTER
    MARK 0x5A
    TSTART
1:  lw   s2, 0(a1)
    lw   s3, 4(a1)
    lw   s4, 8(a1)
    lw   s5, 12(a1)
    sw   s2, 0(a2)
    sw   s3, 4(a2)
    sw   s4, 8(a2)
    sw   s5, 12(a2)
    addi a1, a1, 16
    addi a2, a2, 16
    addi a3, a3, -4
    bnez a3, 1b
    TEND
    MARK 0x5B
    sw   zero, 8(a0)
    LEAVE

/* ---- 3. MUL / DIV ---- */
/* single op: res[2] = a1 OP a2 */
.macro ONEOP name, insn
    .globl k_one_\name
    .balign 16
k_one_\name:
    TSTART
    \insn a3, a1, a2
    TEND
    sw   a3, 8(a0)
    ret
.endm
    ONEOP add,  add
    ONEOP mul,  mul
    ONEOP div,  div
    ONEOP divu, divu
    ONEOP rem,  rem
    ONEOP remu, remu

/* 16 back-to-back dependent MULs: s0 = s0 * a2 (s0 = a1) */
    .globl k_mul_dep16
    .balign 16
k_mul_dep16:
    ENTER
    mv   s0, a1
    TSTART
    .rept 16
    mul  s0, s0, a2
    .endr
    TEND
    sw   s0, 8(a0)
    LEAVE

/* 16 back-to-back independent MULs (same sources, 8 destinations x2) */
    .globl k_mul_ind16
    .balign 16
k_mul_ind16:
    ENTER
    TSTART
    .rept 2
    mul  s2, a1, a2
    mul  s3, a1, a2
    mul  s4, a1, a2
    mul  s5, a1, a2
    mul  s6, a1, a2
    mul  s7, a1, a2
    mul  s8, a1, a2
    mul  s9, a1, a2
    .endr
    TEND
    sw   s9, 8(a0)
    LEAVE

/* 8 back-to-back dependent DIVs: s0 = s0 / a2 (s0 = a1) */
    .globl k_div_dep8
    .balign 16
k_div_dep8:
    ENTER
    mv   s0, a1
    TSTART
    .rept 8
    div  s0, s0, a2
    .endr
    TEND
    sw   s0, 8(a0)
    LEAVE

/* 8 back-to-back independent DIVs */
    .globl k_div_ind8
    .balign 16
k_div_ind8:
    ENTER
    TSTART
    div  s2, a1, a2
    div  s3, a1, a2
    div  s4, a1, a2
    div  s5, a1, a2
    div  s6, a1, a2
    div  s7, a1, a2
    div  s8, a1, a2
    div  s9, a1, a2
    TEND
    sw   s9, 8(a0)
    LEAVE

/* MUL immediately followed by a dependent ADD (result forwarding) */
    .globl k_mul_use
    .balign 16
k_mul_use:
    TSTART
    mul  a3, a1, a2
    add  a3, a3, a1
    TEND
    sw   a3, 8(a0)
    ret
