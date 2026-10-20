// uart_tb.sv — Unit test for rtl/soc/uart.sv with tx looped back to rx.
//   * 16 back-to-back DATA writes (no polling) fill the TX FIFO: all 16 bytes
//     come out of the serial line in order and are received back (no drops)
//   * 17th write while full -> dropped, TX_OVERFLOW set; W1C clears it
//   * RX FIFO overflow (17 bytes unread) -> RX_OVERRUN; DATA read when empty
//     returns valid=0; BAUDDIV readback / clamp
`timescale 1ns/1ps
import soc_map_pkg::*;
module uart_tb;
    localparam int DIV = 8;
    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    logic sel = 0, we = 0, re = 0;
    logic [3:0] addr = 0;
    logic [31:0] wdata = 0, rdata;
    logic tx, tx_push; logic [7:0] tx_push_byte;
    uart #(.DIV_RESET(DIV), .DEPTH(16)) dut (.clk, .rst_n, .sel, .we, .re, .addr, .wdata,
        .rdata, .tx, .rx(tx), .tx_push, .tx_push_byte);

    int errors = 0;
    task automatic chk(string what, logic [31:0] got, exp);
        if (got !== exp) begin $display("  FAIL %-36s got=%08h exp=%08h", what, got, exp); errors++; end
        else              $display("  ok   %-36s = %08h", what, got);
    endtask
    task automatic wr(logic [3:0] a, logic [31:0] d);   // single-cycle store
        @(negedge clk); sel = 1; we = 1; addr = a; wdata = d;
        @(negedge clk); sel = 0; we = 0;
    endtask
    task automatic rd(logic [3:0] a, output logic [31:0] d);  // single-cycle load
        @(negedge clk); sel = 1; re = 1; addr = a; #1 d = rdata;
        @(negedge clk); sel = 0; re = 0;
    endtask

    logic [31:0] v;
    int got_bytes;
    initial begin
        #22 rst_n = 1;
        $display("uart_tb (DIV=%0d, loopback)", DIV);
        rd(UART_STATUS, v);  chk("reset STATUS (TX ready+idle)", v, 32'h3);
        rd(UART_BAUDDIV, v); chk("BAUDDIV reset", v, DIV);
        rd(UART_DATA, v);    chk("DATA read when RX empty", v, 0);

        // burst: 17 consecutive store cycles, no polling (16 in FIFO + 1 in
        // the shifter), then an 18th write that must overflow
        @(negedge clk); sel = 1; we = 1; addr = UART_DATA;
        for (int i = 0; i < 17; i++) begin wdata = 8'h41 + i; @(negedge clk); end
        sel = 0; we = 0;
        rd(UART_STATUS, v);
        chk("no TX_OVERFLOW after 17-byte burst", v[4], 0);
        chk("TX_READY=0 (FIFO full)", v[0], 0);
        wr(UART_DATA, 8'h7A);
        rd(UART_STATUS, v);
        chk("TX_OVERFLOW after write when full", v[4], 1);
        chk("TX not idle while sending", v[1], 0);
        wr(UART_STATUS, 32'h10);
        rd(UART_STATUS, v);  chk("TX_OVERFLOW cleared (W1C)", v[4], 0);

        // receive the loopback while it arrives (polling RX_VALID)
        got_bytes = 0;
        fork
            while (got_bytes < 17) begin
                rd(UART_DATA, v);
                if (v[8]) begin
                    if (v[7:0] !== 8'(8'h41 + got_bytes)) begin
                        $display("  FAIL rx byte %0d got %02h exp %02h", got_bytes, v[7:0], 8'h41 + got_bytes);
                        errors++;
                    end
                    got_bytes++;
                end
            end
            begin repeat (20 * 10 * DIV) @(posedge clk); end
        join_any
        disable fork;
        chk("burst bytes received in order", got_bytes, 17);
        repeat (2 * 10 * DIV) @(posedge clk);
        rd(UART_STATUS, v);
        chk("TX idle after burst", v[1], 1);
        chk("dropped byte (0x7A) never sent", v[2], 0);
        chk("no RX_OVERRUN", v[3], 0);

        // RX overrun: send 17 bytes (two bursts) without reading
        for (int i = 0; i < 17; i++) begin
            rd(UART_STATUS, v);
            while (!v[0]) rd(UART_STATUS, v);
            wr(UART_DATA, i);
        end
        repeat (18 * 10 * DIV + 100) @(posedge clk);
        rd(UART_STATUS, v);
        chk("RX_OVERRUN after 17 unread bytes", v[3], 1);
        rd(UART_DATA, v);    chk("first byte kept", v, 32'h100);
        wr(UART_STATUS, 32'h08);
        rd(UART_STATUS, v);  chk("RX_OVERRUN cleared (W1C)", v[3], 0);

        wr(UART_BAUDDIV, 1);
        rd(UART_BAUDDIV, v); chk("BAUDDIV clamps to 4", v, 4);

        if (errors == 0) $display("UART TEST: PASS");
        else             $display("UART TEST: FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
