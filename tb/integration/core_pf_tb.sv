// core_pf_tb.sv — MMU page-fault traps on core_top (USE_MMU=1, D-side Sv32).
// The program (gen_prog.py, core_pf_prog.hex) first enables Sv32 with
// CSRW satp = 0x80000002 (root PA 0x2000); priv_mode=S from the tb port lets
// the MMU translate (the core itself is M-only). It then does a faulting load (unmapped megapage), a faulting store (read-only page)
// and a faulting lb after a two-level walk (invalid L0 PTE). The M-mode
// handler logs {mcause, mtval, mepc} to memory, advances mepc by 4 and MRETs.
// Checks: causes 13/15/13, mtval = faulting VA, mepc = faulting pc, rd not
// written, faulting store never on the bus, execution continues after mret.
`timescale 1ns/1ps
module core_pf_tb;
    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    logic [31:0] imem_addr, imem_rdata, dmem_addr, dmem_wdata, dmem_rdata;
    logic        dmem_re, dmem_we, mmu_fault;
    logic [3:0]  dmem_wstrb;
    logic [31:0] mem [0:4095];
    localparam logic [31:0] SENT = 32'hDEAD_BEEF;
    // fault pcs printed by gen_prog.py
    localparam logic [31:0] PC_LD = 32'h38, PC_ST = 32'h40, PC_LD2 = 32'h4C;
    initial begin
        for (int k = 0; k < 4096; k++) mem[k] = 32'h0;
        $readmemh("tb/integration/core_pf_prog.hex", mem, 0, 127);
        mem[32'h180 >> 2]  = SENT;                // target of the faulting store
        mem[32'h2004 >> 2] = 32'h0000_00C7;       // L1[1]: VA 0x400000 -> PA 0, V|R|W|A|D
        mem[32'h2008 >> 2] = 32'h0000_0000;       // L1[2]: invalid
        mem[32'h200C >> 2] = 32'h0000_0043;       // L1[3]: VA 0xC00000 -> PA 0, V|R|A (no W)
        mem[32'h2010 >> 2] = 32'h0000_0C01;       // L1[4]: pointer -> L0 table at PA 0x3000
        mem[32'h3014 >> 2] = 32'h0000_0000;       // L0[5]: invalid leaf
    end
    assign imem_rdata = mem[imem_addr[13:2]];
    assign dmem_rdata = mem[dmem_addr[13:2]];
    int bad_wr = 0;
    always @(posedge clk)
        if (dmem_we) begin
            if (dmem_addr[13:2] == (32'h180 >> 2)) bad_wr++;
            for (int b = 0; b < 4; b++)
                if (dmem_wstrb[b]) mem[dmem_addr[13:2]][8*b +: 8] <= dmem_wdata[8*b +: 8];
        end

    core_top #(.CACHE_BASE(32'h0), .CACHE_LIMIT(32'h200), .USE_MMU(1'b1)) dut (
        .clk, .rst_n, .imem_addr, .imem_rdata,
        .dmem_re, .dmem_we, .dmem_addr, .dmem_wdata, .dmem_wstrb, .dmem_rdata,
        .meip(1'b0), .mtip(1'b0), .msip(1'b0),
        .priv_mode(2'b01), .mmu_fault);

    // trace every trap taken by the core
    always @(posedge clk)
        if (rst_n && dut.p_trap)
            $display("  trap @pc %08h: mcause=%0d mtval=%08h -> mtvec %08h",
                     dut.pc_ex, dut.p_cause, dut.vaddr, dut.p_redirect_pc);

    int errors = 0;
    task automatic chk(string name, logic [31:0] got, logic [31:0] exp);
        if (got !== exp) begin errors++; $display("  FAIL %-30s got %08h exp %08h", name, got, exp); end
        else                          $display("  ok   %-30s = %08h", name, got);
    endtask
    task automatic chk_trap(int n, string what, logic [31:0] cause, logic [31:0] tval, logic [31:0] epc);
        logic [31:0] a; a = 32'h300 + 12 * n;
        chk($sformatf("%s mcause", what), mem[a >> 2],       cause);
        chk($sformatf("%s mtval",  what), mem[(a + 4) >> 2], tval);
        chk($sformatf("%s mepc",   what), mem[(a + 8) >> 2], epc);
        if (mem[a >> 2] === cause && mem[(a + 4) >> 2] === tval && mem[(a + 8) >> 2] === epc)
            $display("PASS: %s page fault: mcause=%0d mtval=0x%08h mepc=0x%08h", what, cause, tval, epc);
    endtask
    int cyc = 0;
    initial begin
        #22 rst_n = 1;
        while (mem[32'h3F0 >> 2] !== 32'hC0DE_500D && cyc < 3000) begin @(posedge clk); cyc++; end
        repeat (5) @(posedge clk);
        $display("core PF test: signature after %0d cycles", cyc);
        chk_trap(0, "load",       32'd13, 32'h0080_0024, PC_LD);
        chk_trap(1, "store",      32'd15, 32'h00C0_0180, PC_ST);
        chk_trap(2, "load(L0)",   32'd13, 32'h0100_5007, PC_LD2);
        chk("traps taken (x24)",            dut.regs[24], 3);
        chk("log ptr advanced (x31)",       dut.regs[31], 32'h0040_0300 + 36);
        chk("faulting lw rd untouched x10", dut.regs[10], 32'h5A5);
        chk("faulting lb rd untouched x13", dut.regs[13], 32'h5A5);
        chk("post-fault instrs ran once",   dut.regs[20], 3);
        chk("PA 0x180 not stored",          mem[32'h180 >> 2], SENT);
        chk("faulting sw never on bus",     bad_wr, 0);
        chk("lw via R-only page (x12)",     dut.regs[12], SENT);
        chk("normal sw after traps",        mem[32'h184 >> 2], 32'h77);
        chk("completion signature",         mem[32'h3F0 >> 2], 32'hC0DE_500D);
        chk("mcause CSR (last)",            dut.u_priv.u_csr.mcause_r, 13);
        chk("mmu_fault flag",               mmu_fault, 1);
        if (errors == 0) $display("CORE PAGE FAULT: PASS"); else $display("CORE PAGE FAULT: FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
