/* crt0.S — reset entry for main RAM (0x0001_0000).
 * The Boot ROM stub at the reset vector (0x0) jumps here.
 *   - set mtvec to a trap catcher, sp to the top of RAM
 *   - zero .bss (.data is already in place: the image is loaded into RAM)
 *   - call main(); GPIO_OUT = return value; DONE = 1; spin
 */
    .section .text.start, "ax"
    .globl _start
_start:
    la    t0, trap_catch
    csrw  mtvec, t0
    la    sp, _stack_top
    la    t0, __bss_start
    la    t1, __bss_end
1:  bgeu  t0, t1, 2f
    sw    zero, 0(t0)
    addi  t0, t0, 4
    j     1b
2:  call  main
finish:
    li    t1, 0x204          /* GPIO_OUT = exit code (low byte) */
    sw    a0, 0(t1)
    li    t2, 0x230          /* wait for UART TX idle */
3:  lw    t3, 4(t2)
    andi  t3, t3, 2
    beqz  t3, 3b
    li    t1, 0x208          /* DONE */
    li    t3, 1
    sw    t3, 0(t1)
4:  j     4b

    .balign 4
trap_catch:                  /* unexpected trap: exit code 0xEE */
    li    a0, 0xEE
    j     finish
