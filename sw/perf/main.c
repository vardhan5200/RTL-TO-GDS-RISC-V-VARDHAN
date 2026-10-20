/* main.c — microbenchmarks for soc_core_top (integrated pipelined core).
 * Timed kernels live in bench.S (mcycle/minstret windows); this file runs
 * them, checks every functional result, and prints one "PERF ..." line per
 * measurement over the UART.  Speed is never a pass/fail criterion: only
 * wrong results are counted (exit code = number of failed checks).
 * Mark ids (perf_mark_id) must match the name table in tb/perf/perf_tb.sv. */
#include <stdint.h>
#include "soc.h"
#include "uart.h"

typedef uint32_t u32;
typedef int32_t  s32;

volatile u32 perf_mark_id;
static int errors;

/* ---- kernels (bench.S) ---- */
void k_empty(u32 *r);
void k_cpi_loop(u32 *r, u32 n);
void k_ic_small(u32 *r, u32 n);
void k_ic_big(u32 *r, u32 n);
void k_ld_stride(u32 *r, const volatile u32 *base, u32 n, u32 stride);
void k_sum(u32 *r, const volatile u32 *base, u32 words);
void k_copy(u32 *r, const volatile u32 *src, volatile u32 *dst, u32 words);
void k_one_add(u32 *r, u32 a, u32 b);
void k_one_mul(u32 *r, u32 a, u32 b);
void k_one_div(u32 *r, u32 a, u32 b);
void k_one_divu(u32 *r, u32 a, u32 b);
void k_one_rem(u32 *r, u32 a, u32 b);
void k_one_remu(u32 *r, u32 a, u32 b);
void k_mul_dep16(u32 *r, u32 a, u32 b);
void k_mul_ind16(u32 *r, u32 a, u32 b);
void k_div_dep8(u32 *r, u32 a, u32 b);
void k_div_ind8(u32 *r, u32 a, u32 b);
void k_mul_use(u32 *r, u32 a, u32 b);

/* ---- tiny output helpers (decimal, x.yyy fixed point) ---- */
static void put_dec(u32 v)
{
    char b[11]; int n = 0;
    do { b[n++] = (char)('0' + v % 10u); v /= 10u; } while (v);
    while (n) uart_putc(b[--n]);
}
static void put_sdec(s32 v) { if (v < 0) { uart_putc('-'); put_dec((u32)-v); } else put_dec((u32)v); }
static void put_hex(u32 v)
{
    uart_puts("0x");
    for (int i = 28; i >= 0; i -= 4) uart_putc("0123456789abcdef"[(v >> i) & 15u]);
}
/* num/den with 3 decimals (num*1000 must fit in 32 bits) */
static void put_fix3(u32 num, u32 den)
{
    u32 q = den ? (num * 1000u + den / 2u) / den : 0;
    put_dec(q / 1000u); uart_putc('.');
    u32 f = q % 1000u;
    uart_putc((char)('0' + f / 100u)); uart_putc((char)('0' + f / 10u % 10u)); uart_putc((char)('0' + f % 10u));
}
static void kv(const char *k, u32 v) { uart_putc(' '); uart_puts(k); uart_putc('='); put_dec(v); }
static void kvf(const char *k, u32 n, u32 d) { uart_putc(' '); uart_puts(k); uart_putc('='); put_fix3(n, d); }
static void eol(void) { uart_puts("\r\n"); }

static void check(const char *name, u32 got, u32 exp)
{
    if (got != exp) {
        errors++;
        uart_puts("CHECK "); uart_puts(name); uart_puts(": FAIL got="); put_hex(got);
        uart_puts(" exp="); put_hex(exp); eol();
    }
}

static u32 ovh_cyc, ovh_ins;   /* k_empty window */
static u32 R[4];

static void fence_i(void) { __asm__ volatile ("fence.i" ::: "memory"); }

/* ---------------------------------------------------------------- 1. CPI */
static u32 cpi_ref(u32 n)
{
    u32 acc = 0;
    for (u32 i = n; i; i--) {
        u32 a = acc + i, b = a ^ i, c = b - acc, d = c | a, e = d & b;
        acc += (e << 3) >> 1;
    }
    return acc;
}
static void bench_cpi(void)
{
    static const u32 ns[2] = {10, 200};
    for (int k = 0; k < 2; k++) {
        u32 n = ns[k];
        k_cpi_loop(R, n);            /* warm-up (I-cache) */
        perf_mark_id = 1 + (u32)k;   /* tb ids 1,2 */
        k_cpi_loop(R, n);
        perf_mark_id = 0;
        check("cpi_loop checksum", R[2], cpi_ref(n));
        u32 cyc = R[0] - ovh_cyc, ins = R[1] - ovh_ins;
        uart_puts("PERF cpi_loop:"); kv("iters", n); kv("instr", ins); kv("cycles", cyc);
        kvf("CPI", cyc, ins); kvf("cycles_per_iter", cyc, n); eol();
        check("cpi_loop instret", ins, 11u * n);
    }
}

/* ----------------------------------------------------------- 2. caches */
#define SRAM ((volatile u32 *)0x00000100u)      /* 64 words, D-cacheable */
static volatile u32 ram_buf[1024];              /* main RAM, uncached */
static volatile u32 ram_dst[1024];

static void ic_run(const char *name, int big, u32 n, int cold, u32 id)
{
    if (cold) fence_i();                        /* invalidate the whole I-cache */
    perf_mark_id = id;
    if (big) k_ic_big(R, n); else k_ic_small(R, n);
    perf_mark_id = 0;
    check(name, R[2], (big ? 64u : 16u) * n);
    u32 cyc = R[0] - ovh_cyc, ins = R[1] - ovh_ins;
    uart_puts("PERF "); uart_puts(name); uart_puts(cold ? ": state=cold" : ": state=warm");
    kv("iters", n); kv("instr", ins); kv("cycles", cyc); kvf("CPI", cyc, ins);
    kvf("cycles_per_iter", cyc, n); eol();
}

static u32 dc_run(const char *name, const volatile u32 *base, u32 n, u32 stride, u32 id)
{
    perf_mark_id = id;
    k_ld_stride(R, base, n, stride);
    perf_mark_id = 0;
    u32 exp = 0;
    for (u32 i = 0; i < n; i++) exp += base[i * (stride / 4u)];
    check(name, R[2], exp);
    u32 cyc = R[0] - ovh_cyc;
    uart_puts("PERF "); uart_puts(name); uart_puts(":"); kv("loads", n); kv("stride_bytes", stride);
    kv("cycles", cyc); kvf("cycles_per_load", cyc, n); eol();
    return cyc;
}

static void bench_cache(void)
{
    /* I-cache: 8 lines x 16 B = 128 B, direct mapped (core_top default). */
    ic_run("icache_small_loop", 0, 1,  1, 10);   /* 72 B body, after fence.i */
    ic_run("icache_small_loop", 0, 50, 0, 11);   /* steady state */
    ic_run("icache_big_loop",   1, 1,  1, 12);   /* 264 B body > cache */
    ic_run("icache_big_loop",   1, 50, 0, 13);

    /* D-cache: only [0x0, 0x200) (ROM + 256 B SRAM) is cacheable; stores are
     * write-through, no-allocate, so filling SRAM leaves the lines cold. */
    for (u32 i = 0; i < 64; i++) SRAM[i] = 0x1000u + i * 3u;
    for (u32 i = 0; i < 64; i++) ram_buf[i] = 0x1000u + i * 3u;
    u32 c0 = dc_run("dcache_sram_seq_cold", SRAM,      32, 4,  20);  /* 0x100-0x17f */
    u32 c1 = dc_run("dcache_sram_seq_warm", SRAM,      32, 4,  21);
    u32 c2 = dc_run("dcache_sram_line_cold", SRAM + 32, 8, 16, 22);  /* 0x180-0x1ff, 1 load/line */
    u32 c3 = dc_run("dcache_sram_line_warm", SRAM + 32, 8, 16, 23);
    u32 c4 = dc_run("uncached_ram_seq",      ram_buf,  32, 4,  24);
    uart_puts("PERF dcache_delta:"); kv("seq_cold_minus_warm_cycles", c0 - c1);
    kv("line_cold_minus_warm_cycles", c2 - c3); 
    uart_puts(" uncached_minus_cached_warm_cycles="); put_sdec((s32)(c4 - c1)); eol();
}

/* ------------------------------------------------------------ 3. MUL/DIV */
/* RISC-V M semantics (spec table 7.1) */
static u32 ref_div(u32 a, u32 b)  { if (b == 0) return 0xFFFFFFFFu; if (a == 0x80000000u && b == 0xFFFFFFFFu) return a; return (u32)((s32)a / (s32)b); }
static u32 ref_divu(u32 a, u32 b) { return b ? a / b : 0xFFFFFFFFu; }
static u32 ref_rem(u32 a, u32 b)  { if (b == 0) return a; if (a == 0x80000000u && b == 0xFFFFFFFFu) return 0; return (u32)((s32)a % (s32)b); }
static u32 ref_remu(u32 a, u32 b) { return b ? a % b : a; }
static u32 ref_mul(u32 a, u32 b)  { return a * b; }

typedef void (*kfn)(u32 *, u32, u32);
static u32 op_lat(kfn f, u32 a, u32 b, u32 exp, const char *name)
{
    f(R, a, b);
    check(name, R[2], exp);
    return R[0];
}

static void bench_muldiv(void)
{
    static const u32 cases[][2] = {
        {100, 7}, {(u32)-100, 7}, {100, (u32)-7}, {7, 100}, {0x7FFFFFFFu, 1},
        {0, 5}, {0xFFFFFFFFu, 0x10000u}, {12345, 0}, {0x80000000u, 0xFFFFFFFFu}, {(u32)-1, (u32)-1},
    };
    /* reference: a single-cycle ADD in the same window */
    k_one_add(R, 1, 2); k_one_add(R, 1, 2);
    u32 base = R[0];
    check("add", R[2], 3);
    uart_puts("PERF mdiv_ref: add_window_cycles="); put_dec(base);
    uart_puts(" (latency = window - add_window + 1)"); eol();
    for (unsigned i = 0; i < sizeof cases / sizeof cases[0]; i++) {
        u32 a = cases[i][0], b = cases[i][1];
        k_one_mul(R, a, b);  /* warm the I-cache lines of this group */
        u32 lm = op_lat(k_one_mul,  a, b, ref_mul(a, b),  "mul");
        u32 ld = op_lat(k_one_div,  a, b, ref_div(a, b),  "div");
        u32 lu = op_lat(k_one_divu, a, b, ref_divu(a, b), "divu");
        u32 lr = op_lat(k_one_rem,  a, b, ref_rem(a, b),  "rem");
        u32 lv = op_lat(k_one_remu, a, b, ref_remu(a, b), "remu");
        uart_puts("PERF mdiv_lat: a="); put_sdec((s32)a); uart_puts(" b="); put_sdec((s32)b);
        kv("mul", lm - base + 1); kv("div", ld - base + 1); kv("divu", lu - base + 1);
        kv("rem", lr - base + 1); kv("remu", lv - base + 1);
        uart_puts(" div="); put_sdec((s32)ref_div(a, b)); uart_puts(" rem="); put_sdec((s32)ref_rem(a, b));
        eol();
    }
    /* throughput: back-to-back chains */
    u32 e;
    k_mul_dep16(R, 3, 5); k_mul_dep16(R, 3, 5);
    e = 3; for (int i = 0; i < 16; i++) e *= 5u;
    check("mul_dep16", R[2], e);
    uart_puts("PERF mul_dep16:"); kv("cycles", R[0] - ovh_cyc); kvf("cycles_per_op", R[0] - ovh_cyc, 16); eol();
    k_mul_ind16(R, 1234567, 89); k_mul_ind16(R, 1234567, 89);
    check("mul_ind16", R[2], 1234567u * 89u);
    uart_puts("PERF mul_ind16:"); kv("cycles", R[0] - ovh_cyc); kvf("cycles_per_op", R[0] - ovh_cyc, 16); eol();
    k_div_dep8(R, 0x7FFFFFFFu, 3); k_div_dep8(R, 0x7FFFFFFFu, 3);
    e = 0x7FFFFFFFu; for (int i = 0; i < 8; i++) e /= 3u;
    check("div_dep8", R[2], e);
    uart_puts("PERF div_dep8:"); kv("cycles", R[0] - ovh_cyc); kvf("cycles_per_op", R[0] - ovh_cyc, 8); eol();
    k_div_ind8(R, 1000000, 7); k_div_ind8(R, 1000000, 7);
    check("div_ind8", R[2], 1000000u / 7u);
    uart_puts("PERF div_ind8:"); kv("cycles", R[0] - ovh_cyc); kvf("cycles_per_op", R[0] - ovh_cyc, 8); eol();
    k_mul_use(R, 6, 7); k_mul_use(R, 6, 7);
    check("mul_use", R[2], 48);
    uart_puts("PERF mul_then_dependent_add:"); kv("cycles", R[0] - ovh_cyc); eol();
}

/* ------------------------------------------------------ 4. loads/stores */
static void bench_lsu(void)
{
    static const u32 ns[2] = {256, 1024};
    for (u32 i = 0; i < 1024; i++) { ram_buf[i] = i * 2654435761u; ram_dst[i] = 0; }
    for (int k = 0; k < 2; k++) {
        u32 n = ns[k], exp = 0;
        for (u32 i = 0; i < n; i++) exp += ram_buf[i];
        k_sum(R, ram_buf, 4);                 /* warm I-cache */
        perf_mark_id = 30 + (u32)k;
        k_sum(R, ram_buf, n);
        perf_mark_id = 0;
        check("array_sum", R[2], exp);
        u32 cyc = R[0] - ovh_cyc;
        uart_puts("PERF array_sum:"); kv("words", n); kv("cycles", cyc); kv("instr", R[1] - ovh_ins);
        kvf("cycles_per_word", cyc, n); kvf("bytes_per_cycle", 4u * n, cyc); eol();

        for (u32 i = 0; i < n; i++) ram_dst[i] = 0;
        k_copy(R, ram_buf, ram_dst, 4);
        perf_mark_id = 32 + (u32)k;
        k_copy(R, ram_buf, ram_dst, n);
        perf_mark_id = 0;
        u32 bad = 0;
        for (u32 i = 0; i < n; i++) bad += (ram_dst[i] != ram_buf[i]);
        check("array_copy mismatches", bad, 0);
        cyc = R[0] - ovh_cyc;
        uart_puts("PERF array_copy:"); kv("words", n); kv("cycles", cyc); kv("instr", R[1] - ovh_ins);
        kvf("cycles_per_word", cyc, n); kvf("bytes_per_cycle", 4u * n, cyc);
        kv("bytes_moved", 8u * n); eol();
    }
    /* cached (SRAM) sum for comparison: 64 words, second (warm) pass */
    u32 exp = 0;
    for (u32 i = 0; i < 64; i++) exp += SRAM[i];
    k_sum(R, SRAM, 64); k_sum(R, SRAM, 64);
    check("sram_sum", R[2], exp);
    u32 cyc = R[0] - ovh_cyc;
    uart_puts("PERF array_sum_sram_dcache_warm:"); kv("words", 64); kv("cycles", cyc);
    kvf("cycles_per_word", cyc, 64); kvf("bytes_per_cycle", 256, cyc); eol();
}

/* ------------------------------------------------------- 5. web-like loop */
static u32 slen(const char *s) { u32 n = 0; while (s[n]) n++; return n; }
static int  pfx(const char *s, const char *p) { while (*p) if (*s++ != *p++) return 0; return 1; }
static char *cpy(char *d, const char *s) { while (*s) *d++ = *s++; return d; }
static char *dec(char *d, u32 v)
{
    char b[11]; int n = 0;
    do { b[n++] = (char)('0' + v % 10u); v /= 10u; } while (v);
    while (n) *d++ = b[--n];
    return d;
}

static const char INDEX_BODY[] = "<h1>Hello from RISC-V</h1>\n";

/* Parse "METHOD SP PATH SP ..." and build the response in out[]; returns length. */
static u32 handle(const char *req, char *out)
{
    char method[8], path[32];
    u32 i = 0, j = 0;
    while (req[i] && req[i] != ' ' && j < sizeof method - 1) method[j++] = req[i++];
    method[j] = 0;
    if (req[i] == ' ') i++;
    j = 0;
    while (req[i] && req[i] != ' ' && req[i] != '\r' && j < sizeof path - 1) path[j++] = req[i++];
    path[j] = 0;

    char *p = out;
    if (!(method[0] == 'G' && method[1] == 'E' && method[2] == 'T' && method[3] == 0)) {
        p = cpy(p, "HTTP/1.0 501 Not Implemented\r\nContent-Length: 0\r\n\r\n");
    } else if ((path[0] == '/' && path[1] == 0) || pfx(path, "/index.html")) {
        p = cpy(p, "HTTP/1.0 200 OK\r\nContent-Type: text/html\r\nContent-Length: ");
        p = dec(p, slen(INDEX_BODY));
        p = cpy(p, "\r\n\r\n");
        p = cpy(p, INDEX_BODY);
    } else {
        p = cpy(p, "HTTP/1.0 404 Not Found\r\nContent-Length: 0\r\n\r\n");
    }
    *p = 0;
    return (u32)(p - out);
}

static inline u32 rdcycle(void) { u32 v; __asm__ volatile ("csrr %0, mcycle" : "=r"(v)); return v; }
static inline void mark(u32 tag, u32 id) { GPIO_OUT = (tag << 24) | id; }

static void bench_web(void)
{
    static const char *const reqs[] = {
        "GET /index.html HTTP/1.0\r\n\r\n",
        "GET / HTTP/1.0\r\nHost: soc\r\n\r\n",
        "GET /missing.html HTTP/1.0\r\n\r\n",
        "POST /index.html HTTP/1.0\r\n\r\n",
    };
    static char out[160];
    const u32 nreq = sizeof reqs / sizeof reqs[0];
    u32 sum_h = 0, sum_t = 0;
    handle(reqs[0], out);                      /* warm-up */
    for (u32 r = 0; r < nreq; r++) {
        uart_flush();
        mark(0x5A, 40 + r);
        u32 t0 = rdcycle();
        u32 n = handle(reqs[r], out);
        u32 t1 = rdcycle();
        uart_puts(out);                        /* response goes out on UART TX */
        uart_flush();
        u32 t2 = rdcycle();
        mark(0x5B, 40 + r);
        check("web response length", n, slen(out));
        sum_h += t1 - t0; sum_t += t2 - t0;
        uart_puts("PERF web_request:"); kv("id", r); kv("resp_bytes", n);
        kv("handle_cycles", t1 - t0); kv("with_uart_tx_cycles", t2 - t0); eol();
    }
    uart_puts("PERF web:"); kv("requests", nreq); kvf("avg_handle_cycles", sum_h, nreq);
    kvf("avg_with_uart_tx_cycles", sum_t, nreq); kv("uart_clocks_per_bit", UART_BAUDDIV); eol();
}

int main(void)
{
    uart_puts("PERF-BEGIN\r\n");
    k_empty(R); k_empty(R);
    ovh_cyc = R[0]; ovh_ins = R[1];
    uart_puts("PERF overhead: window_cycles="); put_dec(ovh_cyc); uart_puts(" window_instr="); put_dec(ovh_ins);
    uart_puts(" (subtracted from all kernel numbers)"); eol();
    bench_cpi();
    bench_cache();
    bench_muldiv();
    bench_lsu();
    bench_web();
    uart_puts("PERF-DONE errors="); put_dec((u32)errors); eol();
    return errors;
}
