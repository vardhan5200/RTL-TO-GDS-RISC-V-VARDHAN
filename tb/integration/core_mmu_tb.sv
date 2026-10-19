// core_mmu_tb.sv — core_top with USE_MMU=1 and the D-side MMU enabled via the
// satp/priv_mode bring-up ports (csr_file has no satp yet). Flat 16 KiB memory
// shared by fetch and data; page table walks go over the core's data bus.
`timescale 1ns/1ps
module core_mmu_tb;
    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    logic [31:0] imem_addr, imem_rdata, dmem_addr, dmem_wdata, dmem_rdata;
    logic        dmem_re, dmem_we, mmu_fault;
    logic [3:0]  dmem_wstrb;
    logic [31:0] mem [0:4095];
    initial begin
        for (int k = 0; k < 4096; k++) mem[k] = 32'h0;
        $readmemh("tb/integration/core_mmu_prog.hex", mem, 0, 63);
        mem[32'h104 >> 2]  = 32'h0000_1234;
        mem[32'h2004 >> 2] = 32'h0000_00C7;   // L1[1]: megapage PPN 0, V|R|W|A|D
    end
    assign imem_rdata = mem[imem_addr[13:2]];
    assign dmem_rdata = mem[dmem_addr[13:2]];
    always @(posedge clk)
        if (dmem_we) for (int b = 0; b < 4; b++)
            if (dmem_wstrb[b]) mem[dmem_addr[13:2]][8*b +: 8] <= dmem_wdata[8*b +: 8];

    core_top #(.CACHE_BASE(32'h0), .CACHE_LIMIT(32'h200), .USE_MMU(1'b1)) dut (
        .clk, .rst_n, .imem_addr, .imem_rdata,
        .dmem_re, .dmem_we, .dmem_addr, .dmem_wdata, .dmem_wstrb, .dmem_rdata,
        .meip(1'b0), .mtip(1'b0), .msip(1'b0),
        .satp(32'h8000_0002), .priv_mode(2'b01), .mmu_fault);

    int errors = 0;
    task automatic chk(string name, logic [31:0] got, logic [31:0] exp);
        if (got !== exp) begin errors++; $display("  FAIL %-24s got %08h exp %08h", name, got, exp); end
        else                          $display("  ok   %-24s = %08h", name, got);
    endtask
    initial begin
        #22 rst_n = 1;
        repeat (120) @(posedge clk);
        chk("x3 lw VA 0x400100",    dut.regs[3], 32'h55);
        chk("x4 lw VA 0x400104",    dut.regs[4], 32'h1234);
        chk("x6 faulting lw",       dut.regs[6], 0);
        chk("x7 after fault",       dut.regs[7], 1);
        chk("PA 0x100 written",     mem[32'h100 >> 2], 32'h55);
        chk("mmu_fault",            mmu_fault, 1);
        if (errors == 0) $display("CORE MMU: PASS"); else $display("CORE MMU: FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
