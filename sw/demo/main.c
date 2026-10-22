/* main.c — demo_soc firmware: banner, 7-seg count 0..3, 4x4 matmul on the
 * accelerator, then a tiny line-based UART command shell:
 *   PING    -> PONG
 *   SEG <h> -> 7-seg shows hex digit h (0-9, A-F), OK   (bad digit -> ERR)
 *   MAT     -> rerun the accelerator, 4 result rows, OK
 *   QUIT    -> BYE, program exits (crt0 sets DONE)
 *   other   -> ERR
 * Lines end with "\n" ("\r" ignored); replies end with "\r\n".          */
#include <stdint.h>
#include "demo_soc.h"
#include "uart.h"

static const int16_t mat_a[16] = {
      1,    2,    3,    4,
      5,    6,    7,    8,
     -1,   -2,   -3,   -4,
    100, -200,  300, -400,
};
static const int16_t mat_b[16] = {
      1,    0,   -1,    2,
      0,    1,    2,   -3,
     -2,    3,    0,    1,
     10,  -10,    5, 1000,
};

static void put_int(int32_t v)
{
    char buf[12];
    int n = 0;
    uint32_t u = (v < 0) ? (uint32_t)(-(v + 1)) + 1u : (uint32_t)v;
    if (v < 0) uart_putc('-');
    do { buf[n++] = (char)('0' + u % 10u); u /= 10u; } while (u);
    while (n) uart_putc(buf[--n]);
}

static void delay(unsigned n) { for (volatile unsigned i = 0; i < n; i++) ; }

static void mat_run_and_print(void)
{
    MM_CTRL = 1u;
    while (!(MM_STATUS & MM_DONE))
        ;
    for (int r = 0; r < 4; r++) {
        for (int c = 0; c < 4; c++) {
            if (c) uart_putc(' ');
            put_int((int32_t)MM_C(4 * r + c));
        }
        uart_puts("\r\n");
    }
}

static int read_line(char *buf, int max)
{
    int n = 0;
    for (;;) {
        int ch = uart_getc();
        if (ch == '\n') break;
        if (ch == '\r') continue;
        if (n < max - 1) buf[n++] = (char)ch;
    }
    buf[n] = '\0';
    return n;
}

static int streq(const char *a, const char *b)
{
    while (*a && *a == *b) { a++; b++; }
    return *a == *b;
}

static int hexval(char ch)
{
    if (ch >= '0' && ch <= '9') return ch - '0';
    if (ch >= 'A' && ch <= 'F') return ch - 'A' + 10;
    if (ch >= 'a' && ch <= 'f') return ch - 'a' + 10;
    return -1;
}

static char line[32];

int main(void)
{
    uart_puts("RISC-V demo SoC: 7-seg + UART + matmul4x4\r\n");

    for (int d = 0; d < 4; d++) {
        SEG_VALUE = (uint32_t)d;
        delay(20);
    }
    uart_puts("7SEG count 0..3 done\r\n");

    for (int i = 0; i < 16; i++) {
        MM_A(i) = (uint32_t)(int32_t)mat_a[i];
        MM_B(i) = (uint32_t)(int32_t)mat_b[i];
    }
    uart_puts("C = A x B:\r\n");
    mat_run_and_print();
    uart_puts("READY\r\n");

    for (;;) {
        read_line(line, sizeof line);
        if (streq(line, "PING")) {
            uart_puts("PONG\r\n");
        } else if (line[0] == 'S' && line[1] == 'E' && line[2] == 'G' && line[3] == ' ' &&
                   hexval(line[4]) >= 0 && line[5] == '\0') {
            SEG_VALUE = (uint32_t)hexval(line[4]);
            uart_puts("OK\r\n");
        } else if (streq(line, "MAT")) {
            mat_run_and_print();
            uart_puts("OK\r\n");
        } else if (streq(line, "QUIT")) {
            uart_puts("BYE\r\n");
            break;
        } else {
            uart_puts("ERR\r\n");
        }
    }
    uart_flush();
    return 0;
}
