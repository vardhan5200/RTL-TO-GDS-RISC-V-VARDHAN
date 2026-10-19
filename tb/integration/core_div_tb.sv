// core_div_tb.sv — core_top running tb/integration/core_div_prog.hex (see
// gen_prog.py): DIV/DIVU/REM/REMU incl. 20/3 = 6, signed operands, RISC-V
// corner cases (x/0, INT_MIN/-1), back-to-back dependent DIV->ADD and
// DIV->DIV, DIV followed by a taken branch on its result, and a load/store
// right behind a DIV. Flat 16 KiB memory shared by fetch and data.
`timescale 1ns/1ps
module core_div_tb;
    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    logic [31:0] imem_addr, imem_rdata, dmem_addr, dmem_wdata, dmem_rdata;
    logic        dmem_re, dmem_we, mmu_fault;
    logic [3:0]  dmem_wstrb;
    logic [31:0] mem [0:4095];
    initial begin
        for (int k = 0; k < 4096; k++) mem[k] = 32'h0;
        $readmemh("tb/integration/core_div_prog.hex", mem, 0, 63);
    end
    assign imem_rdata = mem[imem_addr[13:2]];
    assign dmem_rdata = mem[dmem_addr[13:2]];
    always @(posedge clk)
        if (dmem_we) for (int b = 0; b < 4; b++)
            if (dmem_wstrb[b]) mem[dmem_addr[13:2]][8*b +: 8] <= dmem_wdata[8*b +: 8];

    core_top #(.CACHE_BASE(32'h0), .CACHE_LIMIT(32'h200), .USE_MMU(1'b0)) dut (
        .clk, .rst_n, .imem_addr, .imem_rdata,
        .dmem_re, .dmem_we, .dmem_addr, .dmem_wdata, .dmem_wstrb, .dmem_rdata,
        .meip(1'b0), .mtip(1'b0), .msip(1'b0),
        .satp(32'h0), .priv_mode(2'b11), .mmu_fault);

    int cycles = 0, divs = 0, traps = 0, div_stall = 0;
    always @(posedge clk) if (rst_n) begin
        cycles <= cycles + 1;
        if (dut.div_start) divs <= divs + 1;
        if (dut.p_trap)    traps <= traps + 1;
        if (dut.valid_ex && dut.is_div_ex && dut.stall) div_stall <= div_stall + 1;
    end

    int errors = 0;
    task automatic chk(string name, logic [31:0] got, logic [31:0] exp);
        if (got !== exp) begin errors++; $display("  FAIL %-26s got %08h exp %08h", name, got, exp); end
        else                          $display("  ok   %-26s = %08h", name, got);
    endtask
    function automatic logic [31:0] x(int n); return dut.regs[n]; endfunction

    initial begin
        #22 rst_n = 1;
        fork
            wait (dut.regs[31] == 1);
            #20000;
        join_any
        repeat (2) @(posedge clk);
        $display("core DIV test: %0d cycles, divs=%0d, div stall cycles=%0d (%0d/div), traps=%0d",
                 cycles, divs, div_stall, divs ? div_stall / divs : 0, traps);
        chk("x3  div 20/3",            x(3), 6);
        chk("x4  add RAW on div",      x(4), 26);
        chk("x5  divu 20/3",           x(5), 6);
        chk("x6  rem 20%3",            x(6), 2);
        chk("x7  remu 20%3",           x(7), 2);
        chk("x9  div -20/3",           x(9), -6);
        chk("x10 rem -20%3",           x(10), -2);
        chk("x11 divu 0xffffffec/3",   x(11), 32'hFFFF_FFEC / 3);
        chk("x12 remu 0xffffffec%3",   x(12), 32'hFFFF_FFEC % 3);
        chk("x13 div 20/0",            x(13), 32'hFFFF_FFFF);
        chk("x14 rem 20%0",            x(14), 20);
        chk("x15 divu -20/0",          x(15), 32'hFFFF_FFFF);
        chk("x16 remu -20%0",          x(16), -20);
        chk("x19 div INT_MIN/-1",      x(19), 32'h8000_0000);
        chk("x20 rem INT_MIN%-1",      x(20), 0);
        chk("x21 div before beq",      x(21), 6);
        chk("x22 skipped by beq",      x(22), 0);
        chk("x23 beq target",          x(23), 1);
        chk("x25 div before lw",       x(25), 6);
        chk("x26 lw after div",        x(26), 20);
        chk("x27 add lw+div",          x(27), 26);
        chk("x28 sw/lw div result",    x(28), 6);
        chk("x30 div->div RAW",        x(30), 2);
        chk("divs issued",             divs, 18);
        chk("traps",                   traps, 0);
        if (errors == 0) $display("CORE DIV: PASS"); else $display("CORE DIV: FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
