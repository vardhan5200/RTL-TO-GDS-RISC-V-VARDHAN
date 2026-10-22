// demo_soc_tb.sv — "FPGA demo" testbench for rtl/peripherals/demo_soc.sv
// running sw/demo/demo.hex (C firmware) on the integrated pipelined core.
//   * TB UART receiver decodes the serial uart_tx pin  -> "[UART TX] ..."
//   * TB UART sender drives the serial uart_rx pin     -> "[UART RX] ..."
//   * 7-segment pins are decoded back to a hex digit   -> "[7SEG] d"
//   * accelerator result registers vs a TB reference   -> "[MATMUL] ..."
// Every TX line, the 7-seg sequence and the matrix are checked exactly.
`timescale 1ns/1ps
module demo_soc_tb;
    parameter int DIV = 8;                       // UART clocks per bit
    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    logic uart_tx, uart_rx = 1'b1, uart_valid, seg_dp, seg_wr, done, bus_err;
    logic [7:0] uart_byte, gpio_out;
    logic [6:0] seg; logic [3:0] seg_digit; logic [31:0] bus_err_addr;

    demo_soc #(.MEM_FILE("sw/demo/demo.hex"), .UART_DIV(DIV)) dut (
        .clk, .rst_n, .uart_tx, .uart_rx, .uart_byte, .uart_valid,
        .seg, .seg_dp, .seg_digit, .seg_wr, .gpio_out, .done, .bus_err, .bus_err_addr);

    int cycles = 0, errors = 0;
    always @(posedge clk) if (rst_n) cycles++;

    // ---------------- reference matrices (same as sw/demo/main.c) ----------
    int A [0:15], B [0:15];
    initial begin
        A[0] = 1; A[1] = 2; A[2] = 3; A[3] = 4;
        A[4] = 5; A[5] = 6; A[6] = 7; A[7] = 8;
        A[8] = -1; A[9] = -2; A[10] = -3; A[11] = -4;
        A[12] = 100; A[13] = -200; A[14] = 300; A[15] = -400;
        B[0] = 1; B[1] = 0; B[2] = -1; B[3] = 2;
        B[4] = 0; B[5] = 1; B[6] = 2; B[7] = -3;
        B[8] = -2; B[9] = 3; B[10] = 0; B[11] = 1;
        B[12] = 10; B[13] = -10; B[14] = 5; B[15] = 1000;
    end
    int R [0:15];
    initial begin #0.5; for (int r = 0; r < 4; r++) for (int c = 0; c < 4; c++) begin
        R[4*r+c] = 0;
        for (int k = 0; k < 4; k++) R[4*r+c] += A[4*r+k] * B[4*k+c];
    end end

    // ---------------- expected UART TX transcript ----------------
    typedef logic [8*96-1:0] line_t;             // right-justified ASCII
    line_t exp_l [0:31]; int nexp = 0;
    line_t cap_l [0:31]; int ncap = 0;
    task automatic exp_line(input line_t s); exp_l[nexp] = s; nexp++; endtask
    task automatic exp_rows();
        line_t s;
        for (int r = 0; r < 4; r++) begin
            $sformat(s, "%0d %0d %0d %0d", R[4*r], R[4*r+1], R[4*r+2], R[4*r+3]);
            exp_line(s);
        end
    endtask
    initial begin
        #1;
        exp_line("RISC-V demo SoC: 7-seg + UART + matmul4x4");
        exp_line("7SEG count 0..3 done");
        exp_line("C = A x B:"); exp_rows();
        exp_line("READY");
        exp_line("PONG");                         // PING
        exp_line("OK");                           // SEG 7
        exp_rows(); exp_line("OK");               // MAT
        exp_line("ERR");                          // HELLO
        exp_line("ERR");                          // SEG Z
        exp_line("BYE");                          // QUIT
    end
    function automatic void show(input string tag, input line_t s);
        int n; n = 96;
        while (n > 0 && s[8*(n-1) +: 8] == 8'h00) n--;
        $write("%s", tag);
        for (int i = n - 1; i >= 0; i--) $write("%c", s[8*i +: 8]);
        $display("");
    endfunction

    // ---------------- TB UART receiver (serial uart_tx pin) ----------------
    int framing_err = 0, crlf_err = 0;
    initial begin : rx_mon
        logic [7:0] b; line_t cur; logic prev_cr;
        cur = '0; prev_cr = 0;
        @(posedge rst_n);
        forever begin
            @(negedge uart_tx);
            repeat (DIV / 2) @(posedge clk);
            if (uart_tx === 1'b0) begin
                for (int i = 0; i < 8; i++) begin repeat (DIV) @(posedge clk); b[i] = uart_tx; end
                repeat (DIV) @(posedge clk);
                if (uart_tx !== 1'b1) framing_err++;
                if (b == 8'h0A) begin
                    if (!prev_cr) crlf_err++;
                    show("[UART TX] ", cur);
                    cap_l[ncap] = cur; ncap++;
                    cur = '0;
                end else if (b != 8'h0D) cur = {cur[8*95-1:0], b};
                prev_cr = (b == 8'h0D);
            end
        end
    end

    // ---------------- TB UART sender (serial uart_rx pin) ----------------
    task automatic send_byte(input logic [7:0] c);
        uart_rx = 1'b0; repeat (DIV) @(posedge clk);
        for (int i = 0; i < 8; i++) begin uart_rx = c[i]; repeat (DIV) @(posedge clk); end
        uart_rx = 1'b1; repeat (DIV) @(posedge clk);
    endtask
    // send a command line + "\r\n", then wait for `nlines` more TX lines
    task automatic command(input logic [8*16-1:0] cmd, input int nlines);
        int n, target;
        n = 16; while (n > 0 && cmd[8*(n-1) +: 8] == 8'h00) n--;
        show("[UART RX] ", line_t'(cmd));
        target = ncap + nlines;
        for (int i = n - 1; i >= 0; i--) send_byte(cmd[8*i +: 8]);
        send_byte(8'h0D); send_byte(8'h0A);
        wait (ncap >= target);
    endtask

    // ---------------- 7-segment pin decoder ----------------
    function automatic logic [7:0] seg2chr(input logic [6:0] s);
        case (s)
            7'b0111111: return "0"; 7'b0000110: return "1"; 7'b1011011: return "2";
            7'b1001111: return "3"; 7'b1100110: return "4"; 7'b1101101: return "5";
            7'b1111101: return "6"; 7'b0000111: return "7"; 7'b1111111: return "8";
            7'b1101111: return "9"; 7'b1110111: return "A"; 7'b1111100: return "b";
            7'b0111001: return "C"; 7'b1011110: return "d"; 7'b1111001: return "E";
            7'b1110001: return "F"; 7'b0000000: return " ";
            default:    return "?";
        endcase
    endfunction
    logic [8*8-1:0] seg_seq = '0; int nseg = 0;
    always @(posedge clk) if (seg_wr) begin
        $display("[7SEG] %c   (segments gfedcba=%b dp=%b, cycle %0d)", seg2chr(seg), seg, seg_dp, cycles);
        seg_seq = {seg_seq[8*7-1:0], seg2chr(seg)}; nseg++;
    end

    task automatic chk(input string name, input logic [31:0] got, exp);
        if (got !== exp) begin errors++; $display("  FAIL %-30s got %0d exp %0d", name, got, exp); end
        else                          $display("  ok   %-30s = %0d", name, got);
    endtask

    initial begin
        #22 rst_n = 1;
        fork
            begin
                wait (ncap >= 8);                       // banner .. READY
                command("PING",  1);
                command("SEG 7", 1);
                command("MAT",   5);
                command("HELLO", 1);
                command("SEG Z", 1);
                command("QUIT",  1);
                wait (done);
            end
            begin #20_000_000; $display("  TIMEOUT"); errors++; end
        join_any
        repeat (4) @(posedge clk);

        $display("[MATMUL] C = A x B from the accelerator registers (CYCLES=%0d):", dut.u_mm.cyc);
        for (int r = 0; r < 4; r++)
            $display("[MATMUL]   %6d %6d %6d %6d", $signed(dut.u_mm.c[4*r]), $signed(dut.u_mm.c[4*r+1]),
                     $signed(dut.u_mm.c[4*r+2]), $signed(dut.u_mm.c[4*r+3]));

        $display("---- checks (%0d cycles) ----", cycles);
        begin
            int bad; bad = 0;
            for (int n = 0; n < 16; n++)
                if ($signed(dut.u_mm.c[n]) != R[n] || $signed(dut.u_mm.a[n]) != A[n] || $signed(dut.u_mm.b[n]) != B[n]) bad++;
            chk("matmul A/B/C vs TB reference", bad, 0);
            bad = 0;
            for (int k = 0; k < nexp && k < ncap; k++)
                if (cap_l[k] !== exp_l[k]) begin
                    bad++; show("  FAIL got: ", cap_l[k]); show("       exp: ", exp_l[k]);
                end
            chk("UART TX lines", ncap, nexp);
            chk("UART TX line mismatches", bad, 0);
        end
        chk("lines not ending in \\r\\n", crlf_err, 0);
        chk("UART framing errors", framing_err, 0);
        chk("7-seg writes", nseg, 5);
        if (seg_seq[8*5-1:0] !== "01237") begin
            errors++; $display("  FAIL 7-seg sequence %s exp 01237", seg_seq[8*5-1:0]);
        end else $display("  ok   7-seg sequence                 = %s", seg_seq[8*5-1:0]);
        chk("7-seg shows 7 at end", seg_digit, 7);
        chk("done", done, 1);
        chk("exit code (gpio_out)", gpio_out, 0);
        chk("bus_err", bus_err, 0);
        chk("UART RX overrun / TX overflow", {dut.u_uart.rx_ovr, dut.u_uart.tx_ovf}, 0);
        if (errors == 0) $display("DEMO SOC TEST: PASS");
        else             $display("DEMO SOC TEST: FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
