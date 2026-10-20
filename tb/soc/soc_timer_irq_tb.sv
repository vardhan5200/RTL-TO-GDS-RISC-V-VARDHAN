// soc_timer_irq_tb.sv — Timer interrupt end-to-end on the integrated core:
// soc_core_top runs tb/soc/soc_timer_irq_prog.hex (gen_timer_irq_prog.py).
//   timer match -> irq_ctrl PENDING[0] -> (ENABLE mask) -> irq -> core meip
//   -> mip.MEIP -> trap to mtvec (mcause 0x8000000B) -> handler clears the
//   timer flag (W1C) + ACKs irq_ctrl -> mret.
// Checks: no trap while irq_ctrl masks the source, exactly 2 interrupts
// taken, mcause = MEI, irq deasserts after each handler, no re-entry,
// mstatus.MIE restored by mret, no unexpected exceptions / bus errors.
`timescale 1ns/1ps
module soc_timer_irq_tb;
    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    logic irq, uart_valid, done, bus_err;
    logic [7:0] uart_byte, gpio_out;
    logic [31:0] bus_err_addr;

    soc_core_top #(.ROM_FILE("tb/soc/soc_timer_irq_prog.hex")) dut (
        .clk, .rst_n, .ext_irq(7'd0), .irq, .uart_byte, .uart_valid, .gpio_out,
        .done, .bus_err, .bus_err_addr);

    int cycles = 0, irqs_taken = 0, irq_rises = 0, traps = 0, mrets = 0;
    int masked_trap = 0, high_after_mret = 0, irq_cyc;
    logic irq_q = 0;
    always @(posedge clk) if (rst_n) begin
        cycles <= cycles + 1;
        irq_q  <= irq;
        if (irq && !irq_q) begin
            irq_rises <= irq_rises + 1; irq_cyc = cycles;
            $display("  [%0d] irq asserted   (timer COUNT=%0d, PENDING=%02h, ENABLE=%02h)",
                     cycles, dut.u_timer.count, dut.u_irq.pending, dut.u_irq.enable);
        end
        if (!irq && irq_q)
            $display("  [%0d] irq deasserted (handler cleared timer STATUS + ACK)", cycles);
        if (dut.core.p_trap) traps <= traps + 1;
        if (dut.core.p_irq) begin
            irqs_taken <= irqs_taken + 1;
            $display("  [%0d] MEI trap taken: mcause=%08h -> mtvec, %0d cycles after irq rose",
                     cycles, dut.core.p_cause, cycles - irq_cyc);
            if (dut.u_irq.enable[0] == 1'b0) masked_trap <= masked_trap + 1;
        end
        if (dut.core.p_mret) begin
            mrets <= mrets + 1;
            $display("  [%0d] mret", cycles);
            if (irq) high_after_mret <= high_after_mret + 1;
        end
    end

    int errors = 0;
    task automatic chk(string name, logic [31:0] got, logic [31:0] exp);
        if (got !== exp) begin errors++; $display("  FAIL %-36s got %08h exp %08h", name, got, exp); end
        else                          $display("  ok   %-36s = %08h", name, got);
    endtask
    function automatic logic [31:0] x(int n); return dut.core.regs[n]; endfunction

    initial begin
        #22 rst_n = 1;
        fork
            wait (done);
            #20000;
        join_any
        repeat (2) @(posedge clk);
        $display("soc_timer_irq_tb: %0d cycles, traps=%0d irqs=%0d mret=%0d irq-rises=%0d",
                 cycles, traps, irqs_taken, mrets, irq_rises);
        chk("done",                              done, 1);
        chk("PENDING seen while masked (x19)",   x(19), 1);
        chk("no handler run while masked (x30)", x(30), 0);
        chk("no trap while ENABLE[0]=0",         masked_trap, 0);
        chk("handler count (x22)",               x(22), 2);
        chk("1st irq mcause (x31)",              x(31), 32'h8000_000B);
        chk("2nd irq mcause (x26)",              x(26), 32'h8000_000B);
        chk("MEI traps taken",                   irqs_taken, 2);
        chk("total traps (no exceptions)",       traps, 2);
        chk("mrets",                             mrets, 2);
        chk("irq rising edges",                  irq_rises, 2);
        chk("irq high at mret (re-entry risk)",  high_after_mret, 0);
        chk("unexpected exceptions (x23)",       x(23), 0);
        chk("delay loop finished (x7)",          x(7), 0);
        chk("mstatus.MIE restored (x28[3])",     x(28) & 32'h8, 32'h8);
        chk("PENDING at end (x29)",              x(29), 0);
        chk("SRAM[0] handler count",             dut.sram[0], 2);
        chk("SRAM[1] mcause",                    dut.sram[1], 32'h8000_000B);
        chk("irq low at end",                    irq, 0);
        chk("timer STATUS clear at end",         dut.u_timer.match, 0);
        chk("bus_err",                           bus_err, 0);
        $display("  last mepc (x27) = %08h", x(27));
        if (errors == 0) $display("SOC TIMER IRQ (MEI) TEST: PASS");
        else             $display("SOC TIMER IRQ (MEI) TEST: FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
