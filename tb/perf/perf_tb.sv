// perf_tb.sv — runs the sw/perf microbenchmarks (sw/perf/perf.hex, or
// +MEM_HEX=<file>) on soc_core_top and reports:
//   * the program's own "PERF ..." lines (mcycle/minstret, decoded from the
//     serial UART TX line and echoed here);
//   * TB-side probe windows opened/closed by GPIO marker stores
//     (0x5A0000id / 0x5B0000id to 0x204): cycles, retired instructions,
//     I-cache misses (refill starts) and hits (fetches accepted from the
//     cache), D-cache hits/misses, data-bus reads.  The caches have no
//     counters, so these are hierarchical probes on dut.core.
// PASS/FAIL is functional only: program reports "PERF-DONE errors=0", no
// "FAIL" anywhere in the UART stream, the 4 HTTP responses appear in order and
// byte-exact, exit code 0, no bus error / UART framing / overflow.
`timescale 1ns/1ps
module perf_tb;
    parameter int DIV        = 4;          // UART clocks per bit (minimum; the run is UART-bound)
    parameter int MAX_CYCLES = 4_000_000;

    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    logic irq, uart_valid, done, bus_err, uart_tx;
    logic [7:0] uart_byte, gpio_out;
    logic [31:0] bus_err_addr;

    soc_core_top #(.MEM_FILE("sw/perf/perf.hex"), .UART_DIV(DIV)) dut (
        .clk, .rst_n, .ext_irq(7'd0), .irq, .uart_byte, .uart_valid,
        .uart_tx, .uart_rx(1'b1), .gpio_out, .done, .bus_err, .bus_err_addr);

    // ---------------- UART TX capture ----------------
    localparam int CAPN = 16384;
    logic [7:0] cap [0:CAPN-1];
    int ncap = 0, framing_err = 0;
    logic [7:0] lbuf [0:255];
    int nl = 0;
    initial begin : rx_mon
        logic [7:0] b;
        @(posedge rst_n);
        forever begin
            @(negedge uart_tx);
            repeat (DIV / 2) @(posedge clk);
            if (uart_tx === 1'b0) begin
                for (int i = 0; i < 8; i++) begin repeat (DIV) @(posedge clk); b[i] = uart_tx; end
                repeat (DIV) @(posedge clk);
                if (uart_tx !== 1'b1) framing_err++;
                if (ncap < CAPN) cap[ncap] = b;
                ncap++;
                // live echo, one whole line at a time (keeps tb_probe lines separate)
                if (b == 8'h0A) begin
                    for (int i = 0; i < nl; i++) $write("%c", lbuf[i]);
                    $display(""); $fflush; nl = 0;
                end else if (b != 8'h0D && nl < 256) begin lbuf[nl] = b; nl++; end
            end
        end
    end

    // ---------------- probes ----------------
    longint cyc = 0, ret = 0, ic_miss = 0, ic_hit = 0, dc_hit = 0, dc_miss = 0, dbus_rd = 0;
    always @(posedge clk) if (rst_n) begin
        cyc++;
        if (dut.core.retire) ret++;
        if (dut.core.g_icache.u_icache.cnt == 0 && dut.core.g_icache.u_icache.fetch_req &&
            !dut.core.g_icache.u_icache.inval) begin
            if (!dut.core.g_icache.u_icache.hit) ic_miss++;
            else if (!dut.core.stall)            ic_hit++;
        end
        if (dut.core.u_dcache.cnt == 0 && dut.core.u_dcache.req_valid) begin
            if (dut.core.u_dcache.hit) dc_hit++; else dc_miss++;
        end
        if (dut.dmem_re) dbus_rd++;
    end

    function automatic string wname(input int id);
        case (id)
            1:  return "cpi_loop iters=10";
            2:  return "cpi_loop iters=200";
            10: return "icache_small_loop cold iters=1";
            11: return "icache_small_loop iters=50";
            12: return "icache_big_loop cold iters=1";
            13: return "icache_big_loop iters=50";
            20: return "dcache_sram_seq_cold";
            21: return "dcache_sram_seq_warm";
            22: return "dcache_sram_line_cold";
            23: return "dcache_sram_line_warm";
            24: return "uncached_ram_seq";
            30: return "array_sum words=256";
            31: return "array_sum words=1024";
            32: return "array_copy words=256";
            33: return "array_copy words=1024";
            40: return "web_request id=0";
            41: return "web_request id=1";
            42: return "web_request id=2";
            43: return "web_request id=3";
            default: return "unknown";
        endcase
    endfunction

    longint s_cyc [0:63], s_ret [0:63], s_icm [0:63], s_ich [0:63], s_dch [0:63], s_dcm [0:63], s_dbr [0:63];
    bit     active [0:63];
    int     nwin = 0, badwin = 0;
    // a marker store may be held in EX for >1 cycle: act on the first cycle only
    int id;
    always @(posedge clk) if (rst_n && dut.dmem_we && dut.dmem_addr == 32'h204) begin
        id = dut.dmem_wdata[5:0];
        if (id != 0 && dut.dmem_wdata[31:24] == 8'h5A && dut.dmem_wdata[23:6] == 0 && !active[id]) begin
            active[id] = 1;
            s_cyc[id] = cyc; s_ret[id] = ret; s_icm[id] = ic_miss; s_ich[id] = ic_hit;
            s_dch[id] = dc_hit; s_dcm[id] = dc_miss; s_dbr[id] = dbus_rd;
        end else if (id != 0 && dut.dmem_wdata[31:24] == 8'h5B && dut.dmem_wdata[23:6] == 0 && active[id]) begin
            active[id] = 0; nwin++;
            if (wname(id) == "unknown") badwin++;
            $display("PERF tb_probe [%s]: cycles=%0d retired=%0d icache_miss=%0d icache_hit=%0d dcache_hit=%0d dcache_miss=%0d dbus_reads=%0d",
                     wname(id), cyc - s_cyc[id], ret - s_ret[id], ic_miss - s_icm[id], ic_hit - s_ich[id],
                     dc_hit - s_dch[id], dc_miss - s_dcm[id], dbus_rd - s_dbr[id]);
            $fflush;
        end
    end

    // ---------------- checks ----------------
    // Expected byte strings live in plain arrays (pattern of tb/soc/soc_sw_tb.sv;
    // Icarus 12 crashed on string indexing in the end-of-run search).
    // pat 0..3 = HTTP responses in request order, 4 = "PERF-DONE errors=0\r\n", 5 = "FAIL"
    localparam int NPAT = 6;
    logic [7:0] pat [0:NPAT-1][0:127];
    int         patn [0:NPAT-1];
    task automatic set_pat(input int k, input logic [8*128-1:0] v, input int n);
        for (int i = 0; i < n; i++) pat[k][i] = v[8*(n-1-i) +: 8];
        patn[k] = n;
    endtask
    function automatic int find(input int k, input int from);   // index in cap[] or -1
        int i, m, n, lim;
        n = patn[k];
        lim = (ncap < CAPN) ? ncap : CAPN;
        for (i = from; i + n <= lim; i++) begin
            m = 0;
            while (m < n && cap[i + m] == pat[k][m]) m++;
            if (m == n) return i;
        end
        return -1;
    endfunction

    int errors = 0;
    task automatic chk(input string name, input bit ok);
        if (!ok) begin errors++; $display("  FAIL %0s", name); end
        else             $display("  ok   %0s", name);
        $fflush;
    endtask

    int pos, at;
    initial begin
        set_pat(0, "HTTP/1.0 200 OK\015\012Content-Type: text/html\015\012Content-Length: 27\015\012\015\012<h1>Hello from RISC-V</h1>\012", 91);
        set_pat(1, "HTTP/1.0 200 OK\015\012Content-Type: text/html\015\012Content-Length: 27\015\012\015\012<h1>Hello from RISC-V</h1>\012", 91);
        set_pat(2, "HTTP/1.0 404 Not Found\015\012Content-Length: 0\015\012\015\012", 45);
        set_pat(3, "HTTP/1.0 501 Not Implemented\015\012Content-Length: 0\015\012\015\012", 51);
        set_pat(4, "PERF-DONE errors=0\015\012", 20);
        set_pat(5, "FAIL", 4);
        for (int i = 0; i < 64; i++) active[i] = 0;
        #22 rst_n = 1;
        fork
            wait (done);
            begin repeat (MAX_CYCLES) @(posedge clk); $display("  TIMEOUT after %0d cycles", MAX_CYCLES); errors++; end
        join_any
        repeat (4) @(posedge clk);
        $display("");
        $display("perf_tb: reached end-of-run checks"); $fflush;
        $display("perf_tb: %0d cycles total, %0d UART bytes, %0d probe windows", cyc, ncap, nwin); $fflush;
        chk("program finished (done)", done === 1'b1);
        chk("exit code 0 (gpio_out = failed checks)", gpio_out === 8'd0);
        chk("PERF-DONE errors=0 on UART", find(4, 0) >= 0);
        chk("no FAIL in UART stream", find(5, 0) < 0);
        pos = 0;
        at = find(0, pos); chk("HTTP response 0 (GET /index.html -> 200) byte-exact", at >= 0); if (at >= 0) pos = at + patn[0];
        at = find(1, pos); chk("HTTP response 1 (GET / -> 200) byte-exact, after 0", at >= 0); if (at >= 0) pos = at + patn[1];
        at = find(2, pos); chk("HTTP response 2 (GET /missing.html -> 404) byte-exact, after 1", at >= 0); if (at >= 0) pos = at + patn[2];
        at = find(3, pos); chk("HTTP response 3 (POST -> 501) byte-exact, after 2", at >= 0);
        chk("all 19 probe windows opened, closed and named", nwin == 19 && badwin == 0);
        chk("no UART framing errors", framing_err == 0);
        chk("no UART TX overflow", dut.u_uart.tx_ovf === 1'b0);
        chk("no bus error", bus_err === 1'b0);
        chk("capture buffer not overrun", ncap <= CAPN);
        if (errors == 0) $display("PERF SUITE: PASS");
        else             $display("PERF SUITE: FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
