// core_sfence_tb.sv — SFENCE.VMA flushes the D-TLB, the I-TLB and the fetch
// translation register. core_top USE_MMU=1, flat 32 KiB memory; program image
// tb/integration/core_sfence_prog.hex (see gen_prog.py), running in S-mode:
//   load VA 0x1000 (-> PA 0x5000) and call VA 0x2000 (-> PA 0x4000, code P),
//   then rewrite both leaf PTEs in memory (VA 0x1000 -> PA 0x6000, VA 0x2000
//   -> PA 0x7000 = code Q). Without SFENCE the stale TLB entries are used (no
//   walk); after `sfence.vma x2, x0` both sides walk again and use the new
//   mappings. The tb counts leaf-PTE reads per side to show the walks.
`timescale 1ns/1ps
module core_sfence_tb;
    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    logic [31:0] imem_addr, imem_rdata, dmem_addr, dmem_wdata, dmem_rdata;
    logic        dmem_re, dmem_we, mmu_fault;
    logic [3:0]  dmem_wstrb;
    logic [1:0]  cur_priv;
    logic [31:0] mem [0:8191];
    initial begin
        for (int k = 0; k < 8192; k++) mem[k] = 32'h0000_0013;
        for (int k = 32'h2000 >> 2; k < (32'h4000 >> 2); k++) mem[k] = 32'h0;  // page tables
        $readmemh("tb/integration/core_sfence_prog.hex", mem);
        mem[32'h2000 >> 2] = 32'h0000_0C01;   // L1[0] -> L0 at PA 0x3000
        mem[32'h3000 >> 2] = 32'h0000_00CF;   // L0[0]: VA 0x0000 -> PA 0x0000, V|R|W|X|A|D
        mem[32'h3004 >> 2] = 32'h0000_14C7;   // L0[1]: VA 0x1000 -> PA 0x5000, V|R|W|A|D
        mem[32'h3008 >> 2] = 32'h0000_10CB;   // L0[2]: VA 0x2000 -> PA 0x4000, V|R|X|A|D
        mem[32'h300C >> 2] = 32'h0000_0CC7;   // L0[3]: VA 0x3000 -> PA 0x3000, V|R|W|A|D
        mem[32'h5000 >> 2] = 32'h5555_5555;
        mem[32'h6000 >> 2] = 32'h6666_6666;
    end
    assign imem_rdata = mem[imem_addr[14:2]];
    assign dmem_rdata = mem[dmem_addr[14:2]];
    always @(posedge clk)
        if (dmem_we)
            for (int b = 0; b < 4; b++)
                if (dmem_wstrb[b]) mem[dmem_addr[14:2]][8*b +: 8] <= dmem_wdata[8*b +: 8];

    core_top #(.CACHE_BASE(32'h0), .CACHE_LIMIT(32'h200), .USE_MMU(1'b1)) dut (
        .clk, .rst_n, .imem_addr, .imem_rdata,
        .dmem_re, .dmem_we, .dmem_addr, .dmem_wdata, .dmem_wstrb, .dmem_rdata,
        .meip(1'b0), .mtip(1'b0), .msip(1'b0), .mmu_fault, .cur_priv);

    // leaf-PTE reads: D side for VA 0x1000 (PA 0x3004), I side for VA 0x2000 (PA 0x3008)
    int d_walks = 0, i_walks = 0, d_before = -1, i_before = -1, sfences = 0, traps = 0;
    logic [1:0] sfence_priv = 2'bxx;
    always @(posedge clk)
        if (rst_n) begin
            if (dut.ptw_req_valid && dut.ptw_req_ready && dut.ptw_addr[31:0] == 32'h3004) d_walks++;
            if (dut.iptw_req_valid && dut.iptw_req_ready && dut.iptw_addr[31:0] == 32'h3008) i_walks++;
            if (dut.p_sfence) begin
                sfences++; d_before = d_walks; i_before = i_walks; sfence_priv = cur_priv;
                $display("  sfence.vma @pc %08h (priv=%0d): D walks %0d, I walks %0d so far",
                         dut.pc_ex, cur_priv, d_walks, i_walks);
            end
            if (dut.p_trap) traps++;
        end

    int errors = 0;
    task automatic chk(string name, logic [31:0] got, logic [31:0] exp);
        if (got !== exp) begin errors++; $display("  FAIL %-40s got %08h exp %08h", name, got, exp); end
        else                          $display("  ok   %-40s = %08h", name, got);
    endtask
    int cyc = 0;
    initial begin
        #22 rst_n = 1;
        while (mem[32'h3F0 >> 2] !== 32'h5FE7_C00D && cyc < 5000) begin @(posedge clk); cyc++; end
        repeat (5) @(posedge clk);
        $display("core sfence test: signature after %0d cycles", cyc);
        chk("PTEs rewritten (L0[1] -> PPN 6)",         mem[32'h3004 >> 2], 32'h0000_18C7);
        chk("PTEs rewritten (L0[2] -> PPN 7)",         mem[32'h3008 >> 2], 32'h0000_1CCB);
        chk("D: first load (x10)",                     dut.regs[10], 32'h5555_5555);
        chk("D: stale TLB, no sfence (x11)",           dut.regs[11], 32'h5555_5555);
        chk("D: after sfence, new mapping (x12)",      dut.regs[12], 32'h6666_6666);
        chk("I: code trace x9 (P, P stale, Q)",        dut.regs[9],  32'h112);
        chk("D walks for VA 0x1000 before sfence",     d_before, 1);
        chk("I walks for VA 0x2000 before sfence",     i_before, 1);
        chk("D walks after sfence (+1)",               d_walks, 2);
        chk("I walks after sfence (+1)",               i_walks, 2);
        chk("sfence.vma executed once, in S",          {sfences[29:0], sfence_priv}, {30'd1, 2'b01});
        chk("no traps (sfence legal in S)",            traps, 0);
        chk("completion signature",                    mem[32'h3F0 >> 2], 32'h5FE7_C00D);
        if (errors == 0) begin
            $display("PASS: D-TLB: stale 0x55555555 without sfence (no walk), 0x66666666 after sfence.vma (walk)");
            $display("PASS: I-TLB: stale code P without sfence (no walk), code Q after sfence.vma (walk)");
            $display("CORE SFENCE: PASS");
        end else $display("CORE SFENCE: FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
