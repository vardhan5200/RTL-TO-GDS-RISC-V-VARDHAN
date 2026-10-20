// soc_sw_tb.sv — runs the C program sw/nginx_lite (nginx_lite.hex) on
// soc_core_top (+MEM_HEX=<file> overrides the image): Boot ROM stub at the reset vector -> main RAM 0x0001_0000.
// A TB-side UART receiver decodes the serial uart_tx line (8N1, DIV clocks
// per bit); after the "Hello" line arrives a TB-side transmitter sends the
// HTTP request on uart_rx. The decoded TX stream must match exactly.
//   MODE=0: "GET / HTTP/1.0\r\n\r\n"        -> 200 + body
//   MODE=1: "POST /x HTTP/1.0\r\n\r\n"      -> 404
`timescale 1ns/1ps
module soc_sw_tb;
    parameter int    MODE     = 0;
    parameter int    DIV      = 16;                       // clocks per UART bit

    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;                                 // 10 ns clock

    logic irq, uart_valid, done, bus_err, uart_tx, uart_rx = 1'b1;
    logic [7:0] uart_byte, gpio_out;
    logic [31:0] bus_err_addr;

    soc_core_top #(.MEM_FILE("sw/nginx_lite/nginx_lite.hex"), .UART_DIV(DIV)) dut (
        .clk, .rst_n, .ext_irq(7'd0), .irq, .uart_byte, .uart_valid,
        .uart_tx, .uart_rx, .gpio_out, .done, .bus_err, .bus_err_addr);

    // Byte buffers (plain arrays; avoids Icarus string-type limitations).
    // "\015\012" = "\r\n".
    logic [7:0] expv [0:255], req [0:255], cap [0:255], tap [0:255];
    int nexp = 0, nreq = 0, ncap = 0, ntap = 0;
    localparam int HELLO_LEN = 19;   // "Hello from RISC-V\r\n"
    task automatic add_exp(input logic [8*64-1:0] s, input int n);
        for (int i = n - 1; i >= 0; i--) begin expv[nexp] = s[8*i +: 8]; nexp++; end
    endtask
    task automatic add_req(input logic [8*64-1:0] s, input int n);
        for (int i = n - 1; i >= 0; i--) begin req[nreq] = s[8*i +: 8]; nreq++; end
    endtask
    initial begin
        add_exp("Hello from RISC-V\015\012", HELLO_LEN);
        if (MODE == 0) begin
            add_req("GET / HTTP/1.0\015\012\015\012", 18);
            add_exp("HTTP/1.0 200 OK\015\012\015\012", 19);
            add_exp("Hello from RISC-V nginx-lite\015\012", 30);
        end else begin
            add_req("POST /x HTTP/1.0\015\012\015\012", 20);
            add_exp("HTTP/1.0 404 Not Found\015\012\015\012", 26);
        end
    end

    // ---- sim tap: bytes accepted into the TX FIFO ----
    always @(posedge clk) if (uart_valid) begin tap[ntap] = uart_byte; ntap++; end

    // ---- TB UART receiver: decode the serial TX line ----
    int framing_err = 0;
    initial begin : uart_rx_monitor
        logic [7:0] b;
        @(posedge rst_n);
        forever begin
            @(negedge uart_tx);                        // start bit
            repeat (DIV / 2) @(posedge clk);
            if (uart_tx === 1'b0) begin                // valid start bit
                for (int i = 0; i < 8; i++) begin
                    repeat (DIV) @(posedge clk);
                    b[i] = uart_tx;
                end
                repeat (DIV) @(posedge clk);
                if (uart_tx !== 1'b1) framing_err++;
                cap[ncap] = b; ncap++;
            end
        end
    end

    // ---- TB UART transmitter: drive the serial RX line ----
    task automatic send_byte(byte c);
        uart_rx = 1'b0; repeat (DIV) @(posedge clk);  // start
        for (int i = 0; i < 8; i++) begin uart_rx = c[i]; repeat (DIV) @(posedge clk); end
        uart_rx = 1'b1; repeat (DIV) @(posedge clk);  // stop
    endtask

    // which: 0 = request, 1 = captured serial TX, 2 = expected
    task automatic show(string label, input int which);
        int n; logic [7:0] c;
        n = (which == 0) ? nreq : (which == 1) ? ncap : nexp;
        $write("  %s\"", label);
        for (int i = 0; i < n; i++) begin
            c = (which == 0) ? req[i] : (which == 1) ? cap[i] : expv[i];
            if      (c == 8'h0D) $write("\\r");
            else if (c == 8'h0A) $write("\\n");
            else                 $write("%c", c);
        end
        $display("\"");
    endtask

    int errors = 0, cycles = 0;
    always @(posedge clk) if (rst_n) cycles++;
    task automatic chk(string name, logic [31:0] got, logic [31:0] exp);
        if (got !== exp) begin errors++; $display("  FAIL %-28s got %08h exp %08h", name, got, exp); end
        else                          $display("  ok   %-28s = %08h", name, got);
    endtask

    initial begin
        #22 rst_n = 1;
        fork
            begin
                wait (ncap >= HELLO_LEN);
                $display("  [%0d cycles] got hello line, sending %0d request bytes on uart_rx", cycles, nreq);
                show("request : ", 0);
                for (int i = 0; i < nreq; i++) send_byte(req[i]);
                wait (done);
            end
            begin #5_000_000; $display("  TIMEOUT"); errors++; end
        join_any
        repeat (4) @(posedge clk);
        $display("soc_sw_tb (MODE=%0d): %0d cycles, %0d bytes TX", MODE, cycles, ncap);
        $display("---- captured UART TX (decoded from the serial line) ----");
        for (int i = 0; i < ncap; i++) $write("%c", cap[i]);
        $display("---- end ----");
        show("serial  : ", 1);
        show("expected: ", 2);
        begin
            bit same, tapok;
            same = (ncap == nexp); tapok = (ntap == ncap);
            for (int i = 0; i < ncap && i < nexp; i++) if (cap[i] !== expv[i]) same = 0;
            for (int i = 0; i < ncap && i < ntap; i++) if (cap[i] !== tap[i]) tapok = 0;
            if (!same) begin errors++; $display("  FAIL serial TX stream != expected"); end
            else                       $display("  ok   serial TX stream matches expected exactly (%0d bytes)", nexp);
            if (!tapok) begin errors++; $display("  FAIL TX FIFO tap (%0d) != serial stream (%0d): dropped/duplicated byte", ntap, ncap); end
            else                        $display("  ok   TX FIFO tap == serial stream (no drops)");
        end
        chk("done",                   done, 1);
        chk("exit code (gpio_out)",   gpio_out, 0);
        chk("framing errors",         framing_err, 0);
        chk("UART RX overrun",        dut.u_uart.rx_ovr, 0);
        chk("UART TX overflow",       dut.u_uart.tx_ovf, 0);
        chk("bus_err",                bus_err, 0);
        if (errors == 0) $display("SOC SW (nginx-lite MODE=%0d) TEST: PASS", MODE);
        else             $display("SOC SW (nginx-lite MODE=%0d) TEST: FAIL (%0d errors)", MODE, errors);
        $finish;
    end
endmodule
