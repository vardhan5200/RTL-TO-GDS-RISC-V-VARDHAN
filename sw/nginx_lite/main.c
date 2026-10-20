/* main.c — nginx-lite: greet on the UART, read one HTTP request, answer it. */
#include "uart.h"

#define LINE_MAX 64

static int starts_with(const char *s, const char *prefix)
{
    while (*prefix)
        if (*s++ != *prefix++)
            return 0;
    return 1;
}

/* Read one line terminated by '\n'; drops '\r'; returns its length. */
static int read_line(char *buf, int max)
{
    int n = 0;
    for (;;) {
        int c = uart_getc();
        if (c == '\n')
            break;
        if (c == '\r')
            continue;
        if (n < max - 1)
            buf[n++] = (char)c;
    }
    buf[n] = '\0';
    return n;
}

static char request[LINE_MAX];   /* .bss: cleared by crt0 */
static char header[LINE_MAX];

int main(void)
{
    uart_puts("Hello from RISC-V\r\n");

    read_line(request, LINE_MAX);
    while (read_line(header, LINE_MAX) != 0)   /* skip headers up to blank line */
        ;

    if (starts_with(request, "GET /"))
        uart_puts("HTTP/1.0 200 OK\r\n\r\nHello from RISC-V nginx-lite\r\n");
    else
        uart_puts("HTTP/1.0 404 Not Found\r\n\r\n");

    uart_flush();
    return 0;
}
