/* soc.h — SoC register map for soc_core_top (see docs/memory_map.md). */
#ifndef SOC_H
#define SOC_H
#include <stdint.h>

#define REG32(a) (*(volatile uint32_t *)(uintptr_t)(a))

#define GPIO_OUT      REG32(0x00000204u)
#define DONE_REG      REG32(0x00000208u)

#define UART_BASE     0x00000230u
#define UART_DATA     REG32(UART_BASE + 0x0u)  /* W: TX push; R: RX pop {valid[8], byte} */
#define UART_STATUS   REG32(UART_BASE + 0x4u)
#define UART_BAUDDIV  REG32(UART_BASE + 0x8u)

#define UART_TX_READY   (1u << 0)
#define UART_TX_IDLE    (1u << 1)
#define UART_RX_VALID   (1u << 2)
#define UART_RX_OVERRUN (1u << 3)
#define UART_TX_OVERFLOW (1u << 4)

#endif
