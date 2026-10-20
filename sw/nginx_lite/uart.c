/* uart.c — polled UART driver (no interrupts). */
#include "soc.h"
#include "uart.h"

void uart_putc(char c)
{
    while (!(UART_STATUS & UART_TX_READY))
        ;
    UART_DATA = (uint8_t)c;
}

void uart_puts(const char *s)
{
    while (*s)
        uart_putc(*s++);
}

int uart_getc(void)
{
    uint32_t v;
    do {
        v = UART_DATA;              /* pops one byte when bit 8 (valid) is set */
    } while (!(v & 0x100u));
    return (int)(v & 0xFFu);
}

void uart_flush(void)
{
    while (!(UART_STATUS & UART_TX_IDLE))
        ;
}
