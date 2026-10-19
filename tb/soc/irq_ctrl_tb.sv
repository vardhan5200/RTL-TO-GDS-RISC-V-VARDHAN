// irq_ctrl_tb.sv — Unit test for irq_ctrl (enable mask, claim priority,
// W1C ACK, level re-pend, set-beats-clear).
`timescale 1ns/1ps
import soc_map_pkg::*;

module irq_ctrl_tb;
    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    logic        sel = 0, we = 0;
    logic [3:0]  addr = 0;
    logic [31:0] wdata = 0, rdata;
    logic [7:0]  src = 0;
    logic        irq;

    irq_ctrl #(.N(8)) dut (.clk, .rst_n, .sel, .we, .addr, .wdata, .rdata, .src, .irq);

    int errors = 0;
    task automatic check(string what, logic [31:0] got, exp);
        if (got !== exp) begin
            $display("  FAIL %-34s got=%08h exp=%08h", what, got, exp); errors++;
        end else
            $display("  ok   %-34s = %08h", what, got);
    endtask
    task automatic wr(logic [3:0] a, logic [31:0] d);
        @(negedge clk); sel = 1; we = 1; addr = a; wdata = d;
        @(negedge clk); sel = 0; we = 0;
    endtask
    task automatic rd(logic [3:0] a, output logic [31:0] d);
        @(negedge clk); addr = a; #1 d = rdata;
    endtask
    task automatic pulse(logic [7:0] s);
        @(negedge clk); src = s; @(negedge clk); src = 0;
    endtask

    logic [31:0] v;
    initial begin
        #20 rst_n = 1;
        $display("irq_ctrl_tb");
        rd(IRQ_PENDING, v); check("reset PENDING", v, 0);
        rd(IRQ_ENABLE, v);  check("reset ENABLE", v, 0);
        rd(IRQ_CLAIM, v);   check("reset CLAIM", v, 0);
        check("reset irq", irq, 0);

        pulse(8'b0010_0100);                       // sources 2 and 5 pulse
        rd(IRQ_PENDING, v); check("pulses latched in PENDING", v, 32'h24);
        check("irq masked (ENABLE=0)", irq, 0);

        wr(IRQ_ENABLE, 32'h20);                    // enable only 5
        rd(IRQ_ENABLE, v); check("ENABLE readback", v, 32'h20);
        check("irq with src5 enabled", irq, 1);
        rd(IRQ_CLAIM, v);  check("CLAIM id=5", v, 32'h8000_0005);

        wr(IRQ_ENABLE, 32'hFF);
        rd(IRQ_CLAIM, v);  check("CLAIM lowest id=2", v, 32'h8000_0002);
        wr(IRQ_ACK, 32'h04);
        rd(IRQ_PENDING, v); check("ACK bit2 only", v, 32'h20);
        rd(IRQ_CLAIM, v);   check("CLAIM now id=5", v, 32'h8000_0005);
        rd(IRQ_ACK, v);     check("ACK reads 0", v, 0);
        wr(IRQ_ACK, 32'h20);
        check("irq low after all ACKed", irq, 0);

        // level source still high -> re-pends after ACK
        @(negedge clk); src = 8'h01;
        wr(IRQ_ACK, 32'h01);
        rd(IRQ_PENDING, v); check("level src re-pends after ACK", v, 1);
        @(negedge clk); src = 0;
        wr(IRQ_ACK, 32'h01);
        rd(IRQ_PENDING, v); check("cleared once src low", v, 0);

        if (errors == 0) $display("IRQ CTRL TEST: PASS");
        else             $display("IRQ CTRL TEST: FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
