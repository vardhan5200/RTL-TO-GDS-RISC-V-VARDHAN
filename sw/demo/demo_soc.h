/* demo_soc.h — demo_soc peripherals on top of the shared SoC map (soc.h). */
#ifndef DEMO_SOC_H
#define DEMO_SOC_H
#include "soc.h"

#define SEG_BASE      0x00000240u
#define SEG_VALUE     REG32(SEG_BASE + 0x0u)   /* [3:0] digit, [4] blank, [7] dp */

#define MM_BASE       0x00000400u
#define MM_A(i)       REG32(MM_BASE + 0x00u + 4u * (unsigned)(i))
#define MM_B(i)       REG32(MM_BASE + 0x40u + 4u * (unsigned)(i))
#define MM_C(i)       REG32(MM_BASE + 0x80u + 4u * (unsigned)(i))
#define MM_CTRL       REG32(MM_BASE + 0xC0u)   /* bit0 START */
#define MM_STATUS     REG32(MM_BASE + 0xC4u)   /* bit0 BUSY, bit1 DONE */
#define MM_CYCLES     REG32(MM_BASE + 0xC8u)
#define MM_DONE       (1u << 1)
#endif
