// core_fetch_priv_tb.sv — instruction-fetch translation follows the core's
// privilege mode (cur_priv): M never translates, S/U translate when
// satp.MODE = Sv32. core_top USE_MMU=1, flat 32 KiB memory; program image
// tb/integration/core_fetch_priv_prog.hex (see gen_prog.py). With satp on:
//   M: calls VA 0x1000, 0x5000, 0x4000 -> physical code B, A, D (no faults)
//   MRET -> S: VA 0x1000 -> PA 0x5000 = A; VA 0x5000 (invalid PTE) -> PF 12
//   S ecall -> handler (M, at PA 0x6000 whose VA is unmapped, so it only
//   runs untranslated) drops to U at VA 0x4000 (-> PA 0x7000, U=1 page)
//   U: VA 0x4100 -> PA 0x7100 = C; VA 0x1000 (U=0 page) -> PF 12
//   U ecall -> back to M: VA 0x4000 -> physical D again.
// Every snippet appends its id to x9, the handler appends F on a page fault:
// expected trace 0xBADAFCFD.
`timescale 1ns/1ps
module core_fetch_priv_tb;
    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    logic [31:0] imem_addr, imem_rdata, dmem_addr, dmem_wdata, dmem_rdata;
    logic        dmem_re, dmem_we, mmu_fault;
    logic [3:0]  dmem_wstrb;
    logic [1:0]  cur_priv;
    logic [31:0] mem [0:8191];
    localparam logic [31:0] S_ECALL = 32'h60, U_ECALL = 32'h4010;   // VAs (U code: VA 0x4000 = PA 0x7000)
    initial begin
        for (int k = 0; k < 8192; k++) mem[k] = 32'h0000_0013;
        for (int k = 32'h2000 >> 2; k < (32'h4000 >> 2); k++) mem[k] = 32'h0;  // page tables
        $readmemh("tb/integration/core_fetch_priv_prog.hex", mem);
        mem[32'h2000 >> 2] = 32'h0000_0C01;   // L1[0] -> L0 at PA 0x3000
        mem[32'h3000 >> 2] = 32'h0000_00CF;   // L0[0]: VA 0x0000 -> PA 0x0000, V|R|W|X|A|D
        mem[32'h3004 >> 2] = 32'h0000_14CB;   // L0[1]: VA 0x1000 -> PA 0x5000, V|R|X|A|D
        mem[32'h3010 >> 2] = 32'h0000_1CDB;   // L0[4]: VA 0x4000 -> PA 0x7000, V|R|X|U|A|D
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

    // accepted fetches: privilege, bare/translated, physical page
    int m_xlate = 0, s_bare = 0, u_bare = 0, h_xlate = 0, traps = 0, m_traps = 0;
    always @(posedge clk)
        if (rst_n) begin
            if (!dut.stall && !dut.flush && dut.if_valid && dut.csr_satp[31]) begin
                if (cur_priv == 2'b11 && !dut.i_bare) m_xlate++;
                if (cur_priv == 2'b01 && dut.i_bare)  s_bare++;
                if (cur_priv == 2'b00 && dut.i_bare)  u_bare++;
                if (dut.pc[31:12] == 20'h6 && !dut.i_bare) h_xlate++;
            end
            if (dut.p_trap) begin
                traps++;
                if (cur_priv == 2'b11) m_traps++;
                $display("  trap @pc %08h priv=%0d: mcause=%0d mtval=%08h", dut.pc_ex, cur_priv,
                         dut.p_cause, dut.xcpt_tval_c);
            end
        end

    int errors = 0;
    task automatic chk(string name, logic [31:0] got, logic [31:0] exp);
        if (got !== exp) begin errors++; $display("  FAIL %-40s got %08h exp %08h", name, got, exp); end
        else                          $display("  ok   %-40s = %08h", name, got);
    endtask
    function automatic [31:0] lg(input int e, input int w); return mem[(32'h300 >> 2) + 4*e + w]; endfunction
    int cyc = 0;
    initial begin
        #22 rst_n = 1;
        while (mem[32'h3F0 >> 2] !== 32'hF7C4_D00D && cyc < 5000) begin @(posedge clk); cyc++; end
        repeat (5) @(posedge clk);
        $display("core fetch-priv test: signature after %0d cycles", cyc);
        chk("code trace x9 (B A D | A F | C F | D)",  dut.regs[9], 32'hBADA_FCFD);
        chk("traps taken (2 fetch PF + 2 ecall)",     traps, 4);
        chk("no trap while running in M",             m_traps, 0);
        chk("t0 S fetch PF: mcause",      lg(0,0), 12);  chk("t0 mtval", lg(0,1), 32'h5000);
        chk("t0 mepc",                    lg(0,2), 32'h5000); chk("t0 from S (MPP)", lg(0,3) >> 11 & 3, 1);
        chk("t1 S ecall: mcause",         lg(1,0), 9);   chk("t1 mepc", lg(1,2), S_ECALL);
        chk("t2 U fetch PF (U=0 page)",   lg(2,0), 12);  chk("t2 mtval", lg(2,1), 32'h1000);
        chk("t2 mepc",                    lg(2,2), 32'h1000); chk("t2 from U (MPP)", lg(2,3) >> 11 & 3, 0);
        chk("t3 U ecall: mcause",         lg(3,0), 8);   chk("t3 mepc", lg(3,2), U_ECALL);
        chk("M fetches never translated",             m_xlate, 0);
        chk("S fetches never bare (satp on)",         s_bare, 0);
        chk("U fetches never bare (satp on)",         u_bare, 0);
        chk("handler at PA 0x6000 fetched bare",      h_xlate, 0);
        chk("ends in M",                              cur_priv, 2'b11);
        chk("completion signature",                   mem[32'h3F0 >> 2], 32'hF7C4_D00D);
        if (errors == 0) begin
            $display("PASS: M fetched physical B,A,D; S fetched VA 0x1000 -> PA 0x5000 (A); U fetched VA 0x4100 -> PA 0x7100 (C)");
            $display("PASS: fetch page faults (12) only in S (VA 0x5000) and U (VA 0x1000), none in M");
            $display("CORE FETCH PRIV: PASS");
        end else $display("CORE FETCH PRIV: FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
