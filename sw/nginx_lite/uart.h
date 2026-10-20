#ifndef UART_H
#define UART_H
void uart_putc(char c);
void uart_puts(const char *s);
int  uart_getc(void);          /* blocking, returns 0..255 */
void uart_flush(void);         /* wait until the last byte left the TX pin */
#endif
