// timer_irq_tb.sv — Focused test: timer match -> irq_ctrl PENDING[0] -> irq.
`timescale 1ns/1ps
import soc_map_pkg::*;

module timer_irq_tb;
    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    // shared register bus (byte offset, like dmem_addr[3:0])
    logic        t_sel = 0, i_sel = 0, we = 0;
    logic [3:0]  addr = 0;
    logic [31:0] wdata = 0, t_rdata, i_rdata;
    logic        timer_irq, irq;

    timer    u_timer (.clk, .rst_n, .sel(t_sel), .we, .addr, .wdata,
                      .rdata(t_rdata), .irq(timer_irq));
    irq_ctrl #(.N(8)) u_irq (.clk, .rst_n, .sel(i_sel), .we, .addr, .wdata,
                      .rdata(i_rdata), .src({7'd0, timer_irq}), .irq);

    int errors = 0;
    task automatic check(string what, logic [31:0] got, exp);
        if (got !== exp) begin
            $display("  FAIL %-34s got=%08h exp=%08h", what, got, exp); errors++;
        end else
            $display("  ok   %-34s = %08h", what, got);
    endtask

    task automatic wr(bit is_irq, logic [3:0] a, logic [31:0] d);
        @(negedge clk); t_sel = !is_irq; i_sel = is_irq; we = 1; addr = a; wdata = d;
        @(negedge clk); t_sel = 0; i_sel = 0; we = 0;
    endtask
    task automatic rd(bit is_irq, logic [3:0] a, output logic [31:0] d);
        @(negedge clk); addr = a; #1 d = is_irq ? i_rdata : t_rdata;
    endtask

    logic [31:0] v;
    initial begin
        #20 rst_n = 1;
        $display("timer_irq_tb: timer (src 0) -> irq_ctrl -> irq");

        wr(1, IRQ_ENABLE, 32'h1);                 // enable source 0
        rd(0, TIMER_COUNT, v);
        wr(0, TIMER_COMPARE, v + 10);             // match ~10 cycles from now
        rd(1, IRQ_PENDING, v); check("PENDING before match", v, 0);
        check("irq before match", irq, 0);

        repeat (12) @(posedge clk);
        rd(0, TIMER_STATUS, v); check("TIMER STATUS (match flag)", v, 1);
        rd(1, IRQ_PENDING, v);  check("IRQ PENDING[0] set by timer", v, 1);
        rd(1, IRQ_CLAIM, v);    check("IRQ CLAIM {valid,id=0}", v, 32'h8000_0000);
        check("irq output high", irq, 1);

        // service: clear source in the timer, then ACK in the controller
        wr(0, TIMER_STATUS, 32'h1);
        wr(1, IRQ_ACK, 32'h1);
        rd(1, IRQ_PENDING, v); check("PENDING after W1C + ACK", v, 0);
        check("irq output low after ACK", irq, 0);

        // masked: match again with ENABLE=0 -> pending but no irq
        wr(1, IRQ_ENABLE, 32'h0);
        rd(0, TIMER_COUNT, v);
        wr(0, TIMER_COMPARE, v + 5);
        repeat (8) @(posedge clk);
        rd(1, IRQ_PENDING, v); check("PENDING[0] while masked", v, 1);
        check("irq stays low while masked", irq, 0);

        if (errors == 0) $display("TIMER IRQ TEST: PASS");
        else             $display("TIMER IRQ TEST: FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
