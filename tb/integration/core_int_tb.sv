// core_int_tb.sv — self-checking integration test: soc_core_top running
// tb/integration/core_prog.hex (see gen_prog.py) through the integrated core:
// ALU + MUL, loads/stores via the D-cache (miss, refill, hit, write-update,
// byte access), CSR accesses, ECALL + illegal-instruction traps with MRET,
// and a timer interrupt delivered via irq_ctrl -> meip.
`timescale 1ns/1ps
module core_int_tb;
    parameter bit USE_MMU = 1'b0;
    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    logic irq, uart_valid, done, bus_err;
    logic [7:0] uart_byte, gpio_out;
    logic [31:0] bus_err_addr;

    soc_core_top #(.ROM_FILE("tb/integration/core_prog.hex"), .USE_MMU(USE_MMU)) dut (
        .clk, .rst_n, .ext_irq(7'd0), .irq, .uart_byte, .uart_valid, .gpio_out,
        .done, .bus_err, .bus_err_addr);

    int cycles = 0, dc_miss = 0, dc_hit = 0, traps = 0, irqs = 0, mrets = 0, muls = 0;
    always @(posedge clk) if (rst_n) begin
        cycles <= cycles + 1;
        if (dut.core.dc_req_valid && dut.core.u_dcache.cnt == 0) begin
            if (dut.core.u_dcache.hit) dc_hit <= dc_hit + 1; else dc_miss <= dc_miss + 1;
        end
        if (dut.core.p_trap) traps <= traps + 1;
        if (dut.core.p_irq)  irqs  <= irqs + 1;
        if (dut.core.p_mret) mrets <= mrets + 1;
        if (dut.core.mul_start) muls <= muls + 1;
    end

    int errors = 0;
    task automatic chk(string name, logic [31:0] got, logic [31:0] exp);
        if (got !== exp) begin errors++; $display("  FAIL %-28s got %08h exp %08h", name, got, exp); end
        else                          $display("  ok   %-28s = %08h", name, got);
    endtask
    function automatic logic [31:0] x(int n); return dut.core.regs[n]; endfunction

    initial begin
        #22 rst_n = 1;
        fork
            wait (done);
            #20000;
        join_any
        repeat (2) @(posedge clk);
        $display("core integration (USE_MMU=%0d): %0d cycles, D$ miss=%0d hit=%0d, traps=%0d (irq=%0d), mret=%0d, mul=%0d",
                 USE_MMU, cycles, dc_miss, dc_hit, traps, irqs, mrets, muls);
        chk("done",                    done, 1);
        chk("x3 mul 6*7",              x(3), 42);
        chk("x4 mul RAW +1",           x(4), 43);
        chk("x6 lw (D$ miss) +1",      x(6), 43);
        chk("x7 lw (D$ hit, wr-upd)",  x(7), 43);
        chk("x9 lbu",                  x(9), 32'h0000_00AB);
        chk("x10 lb",                  x(10), 32'hFFFF_FFAB);
        chk("x12 csrr misa",           x(12), 32'h4000_1100);
        chk("x13 csrr mscratch",       x(13), 6);
        chk("x14 after ecall/mret",    x(14), 1);
        chk("x21 exception count",     x(21), 2);
        chk("x28 sum causes (11+2)",   x(28), 13);
        chk("x24 last mepc+4 (div)",   x(24), 32'h0000_0058);
        chk("x27 div not written",     x(27), 0);
        chk("x22 irq handler ran",     x(22), 1);
        chk("x26 irq mcause (MEI)",    x(26), 32'h8000_000B);
        chk("SRAM[0]",                 dut.sram[0], 42);
        chk("SRAM[1]",                 dut.sram[1], 43);
        chk("SRAM[2] byte",            dut.sram[2], 32'h0000_AB00);
        chk("irq low at end",          irq, 0);
        chk("bus_err",                 bus_err, 0);
        chk("D$ misses",               dc_miss, 1);
        chk("D$ hits",                 dc_hit, 3);
        chk("irqs taken",              irqs, 1);
        if (errors == 0) $display("CORE INTEGRATION: PASS");
        else             $display("CORE INTEGRATION: FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
