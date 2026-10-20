// core_smode_tb.sv — S-mode trap delegation in the integrated core (core_top,
// USE_MMU=1, architectural privilege). Real program:
//   M : mtvec = MH, stvec = SH, medeleg = {8 ecall-U, 13 load PF}, satp = Sv32
//       (root PA 0x2000), MRET -> S.
//   S : S page load ok; U page load (SUM=0) -> load page fault, delegated:
//       S handler (SH) logs scause/sepc/stval/sstatus, sepc += 4, SRET -> S;
//       then sepc = U_CODE, SRET (SPP = U) -> U.
//   U : U page load ok; S page load -> delegated load PF (S); ECALL -> delegated
//       (scause 8); csrr sstatus -> illegal (2, not delegated) -> M handler (MH);
//       store to the S page -> store PF (15, not delegated) -> M.
// Pages: VA 0x0000 -> PA 0x0000 (S, RWX: code + logs), VA 0x1000 -> PA 0x5000
// (U page), VA 0x4000 -> PA 0x6000 (S page), VA 0x7000 -> PA 0x7000 (U, RX:
// U code; fetch is translated with cur_priv, so U code needs a U|X page).
`timescale 1ns/1ps
module core_smode_tb;
    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    logic [31:0] imem_addr, imem_rdata, dmem_addr, dmem_wdata, dmem_rdata;
    logic        dmem_re, dmem_we, mmu_fault;
    logic [3:0]  dmem_wstrb;
    logic [1:0]  cur_priv;
    logic [31:0] mem [0:8191];

    // ---- tiny assembler ----
    function automatic [31:0] I(input [11:0] imm, input [4:0] rs1, input [2:0] f3, input [4:0] rd, input [6:0] op);
        return {imm, rs1, f3, rd, op}; endfunction
    function automatic [31:0] Sw(input [4:0] rs2, input [4:0] rs1, input [11:0] imm);
        return {imm[11:5], rs2, rs1, 3'd2, imm[4:0], 7'h23}; endfunction
    function automatic [31:0] Beq(input [4:0] rs1, input [4:0] rs2, input [12:0] o);
        return {o[12], o[10:5], rs2, rs1, 3'd0, o[4:1], o[11], 7'h63}; endfunction
    function automatic [31:0] Jal(input [4:0] rd, input [20:0] o);
        return {o[20], o[10:1], o[11], o[19:12], rd, 7'h6f}; endfunction
    function automatic [31:0] Lui(input [4:0] rd, input [19:0] imm);
        return {imm, rd, 7'h37}; endfunction
    function automatic [31:0] Addi(input [4:0] rd, input [4:0] rs1, input [11:0] imm);
        return I(imm, rs1, 3'd0, rd, 7'h13); endfunction
    function automatic [31:0] Lw(input [4:0] rd, input [4:0] rs1, input [11:0] imm);
        return I(imm, rs1, 3'd2, rd, 7'h03); endfunction
    function automatic [31:0] Csr(input [2:0] f3, input [4:0] rd, input [11:0] a, input [4:0] rs1);
        return I(a, rs1, f3, rd, 7'h73); endfunction
    localparam [31:0] ECALL = 32'h0000_0073, MRET = 32'h3020_0073;
    localparam [11:0] MSTATUS = 12'h300, MTVEC = 12'h305, MEPC = 12'h341, MCAUSE = 12'h342,
                      MTVAL = 12'h343, SATP = 12'h180;
    localparam int S_CODE = 32'h100, U_CODE = 32'h7180;

    localparam [31:0] SRET = 32'h1020_0073;
    localparam [11:0] SSTATUS = 12'h100, STVEC = 12'h105, SEPC = 12'h141, SCAUSE = 12'h142,
                      STVAL = 12'h143, MEDELEG = 12'h302;
    localparam int MH = 32'h200, SH = 32'h280, SLOG = 32'h700, MLOG = 32'h780;
    localparam [31:0] U_CSRR_SSTATUS = {SSTATUS, 5'd0, 3'd2, 5'd12, 7'h73};

    int n;
    task automatic org(input int a); n = a >> 2; endtask
    task automatic E(input [31:0] w); mem[n] = w; n++; endtask

    initial begin
        for (int k = 0; k < 8192; k++) mem[k] = 32'h0000_0013;
        // ---- M-mode main @0 ----
        org(0);
        E(Addi(1, 0, MH)); E(Csr(1, 0, MTVEC, 1));
        E(Addi(1, 0, SH)); E(Csr(1, 0, STVEC, 1));
        E(Lui(1, 2)); E(Addi(1, 1, 12'h100)); E(Csr(1, 0, MEDELEG, 1));   // medeleg = 0x2100
        E(Lui(2, 1)); E(Lui(3, 4));                        // x2 = 0x1000, x3 = 0x4000
        E(Addi(28, 0, SLOG)); E(Addi(29, 0, MLOG));
        E(Addi(9, 0, 12'h5A5)); E(Addi(11, 0, 12'h5A5)); E(Addi(12, 0, 12'h5A5));
        E(Addi(4, 0, 12'h077));
        E(Lui(1, 20'h80000)); E(Addi(1, 1, 2)); E(Csr(1, 0, SATP, 1));  // Sv32, root 0x2000
        E(Lui(1, 1)); E(Csr(3, 0, MSTATUS, 1));            // MPP: M -> S
        E(Addi(1, 0, S_CODE)); E(Csr(1, 0, MEPC, 1));
        E(MRET);                                           // -> S
        // ---- S-mode @0x100 ----
        org(S_CODE);
        E(Lw(8, 3, 0));                                    // 0x100 S page -> PA 0x6000
        E(Lw(9, 2, 0));                                    // 0x104 U page from S -> PF 13 (to S)
        E(Lui(1, 7)); E(Addi(1, 1, 12'h180));              // 0x108 x1 = U_CODE
        E(Csr(1, 0, SEPC, 1));                             // 0x110 sepc = U_CODE
        E(SRET);                                           // 0x114 SPP = U -> U
        // ---- U-mode @0x7180 (U page) ----
        org(U_CODE);
        E(Lw(10, 2, 0));                                   // +0x00 U page -> PA 0x5000
        E(Lw(11, 3, 0));                                   // 0x184 S page from U -> PF 13 (to S)
        E(ECALL);                                          // 0x188 cause 8 (to S)
        E(U_CSRR_SSTATUS);                                 // 0x18C illegal 2 (to M)
        E(Sw(4, 3, 0));                                    // 0x190 store PF 15 (to M)
        E(Addi(17, 0, 1));                                 // 0x194
        E(Jal(0, 0));                                      // 0x198 end
        // ---- M handler @0x200 (Bare) ----
        org(MH);
        E(Csr(2, 24, MCAUSE, 0)); E(Csr(2, 25, MEPC, 0));
        E(Csr(2, 26, MTVAL, 0));  E(Csr(2, 19, MSTATUS, 0));
        E(Sw(24, 29, 0)); E(Sw(25, 29, 4)); E(Sw(26, 29, 8)); E(Sw(19, 29, 12));
        E(Addi(29, 29, 16)); E(Addi(13, 13, 1));
        E(Addi(25, 25, 4)); E(Csr(1, 0, MEPC, 25));
        E(MRET);
        // ---- S handler @0x280 (translated, identity page) ----
        org(SH);
        E(Csr(2, 20, SCAUSE, 0)); E(Csr(2, 21, SEPC, 0));
        E(Csr(2, 22, STVAL, 0));  E(Csr(2, 23, SSTATUS, 0));
        E(Sw(20, 28, 0)); E(Sw(21, 28, 4)); E(Sw(22, 28, 8)); E(Sw(23, 28, 12));
        E(Addi(28, 28, 16)); E(Addi(14, 14, 1));
        E(Addi(21, 21, 4)); E(Csr(1, 0, SEPC, 21));
        E(SRET);
        // ---- page tables / data ----
        mem[32'h2000 >> 2] = 32'h0000_0C01;   // L1[0] -> L0 @ PA 0x3000
        mem[32'h3000 >> 2] = 32'h0000_00CF;   // VA 0x0000 -> PPN 0, V|R|W|X|A|D (S)
        mem[32'h3004 >> 2] = 32'h0000_14D7;   // VA 0x1000 -> PPN 5, V|R|W|U|A|D
        mem[32'h3010 >> 2] = 32'h0000_18C7;   // VA 0x4000 -> PPN 6, V|R|W|A|D (S page)
        mem[32'h301C >> 2] = 32'h0000_1CDB;   // VA 0x7000 -> PPN 7, V|R|X|U|A|D (U code)
        mem[32'h1000 >> 2] = 32'h1111_1111; mem[32'h4000 >> 2] = 32'h4444_4444;
        mem[32'h5000 >> 2] = 32'h5555_5555; mem[32'h6000 >> 2] = 32'h6666_6666;
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
        .meip(1'b0), .mtip(1'b0), .msip(1'b0),
        .mmu_fault, .cur_priv);

    logic [1:0] priv_at_s = 2'bxx, priv_at_u = 2'bxx, priv_at_sh = 2'bxx, priv_at_mh = 2'bxx;
    int s_entries = 0, m_entries = 0;
    always @(posedge clk) if (rst_n && dut.valid_ex) begin
        if (dut.pc_ex == S_CODE) priv_at_s  = cur_priv;
        if (dut.pc_ex == U_CODE) priv_at_u  = cur_priv;
        if (dut.pc_ex == SH)     priv_at_sh = cur_priv;
        if (dut.pc_ex == MH)     priv_at_mh = cur_priv;
        if (dut.p_trap) begin
            $display("  trap @pc %08h priv=%0d: cause=%0d -> %s (pc %08h)", dut.pc_ex, cur_priv,
                     dut.p_cause, dut.u_priv.trap_to_s ? "S" : "M", dut.p_redirect_pc);
            if (dut.u_priv.trap_to_s) s_entries++; else m_entries++;
        end
    end

    int pass = 0, fail = 0;
    task automatic chk(string name, logic [31:0] got, logic [31:0] exp);
        if (got !== exp) begin fail++; $display("  FAIL %-36s got %08h exp %08h", name, got, exp); end
        else begin pass++; $display("  ok   %-36s = %08h", name, got); end
    endtask
    function automatic [31:0] sl(input int e, input int w); return mem[(SLOG >> 2) + 4*e + w]; endfunction
    function automatic [31:0] ml(input int e, input int w); return mem[(MLOG >> 2) + 4*e + w]; endfunction
    int cyc = 0;
    initial begin
        #22 rst_n = 1;
        while (!(dut.regs[17] == 1 && dut.pc_ex == U_CODE + 32'h18) && cyc < 4000) begin @(posedge clk); cyc++; end
        repeat (5) @(posedge clk);
        $display("core S-mode test: %0d cycles", cyc);
        chk("S: S page load (x8)",               dut.regs[8],  32'h6666_6666);
        chk("S: U page faulted, x9 untouched",   dut.regs[9],  32'h5A5);
        chk("U: U page load (x10)",              dut.regs[10], 32'h5555_5555);
        chk("U: S page faulted, x11 untouched",  dut.regs[11], 32'h5A5);
        chk("U: csrr sstatus trapped, x12 kept", dut.regs[12], 32'h5A5);
        chk("U: resumed to the end (x17)",       dut.regs[17], 1);
        chk("S-handler traps (x14)",             dut.regs[14], 3);
        chk("M-handler traps (x13)",             dut.regs[13], 2);
        chk("traps routed to S",                 s_entries, 3);
        chk("traps routed to M",                 m_entries, 2);
        chk("store to S page not done",          mem[32'h6000 >> 2], 32'h6666_6666);
        chk("cur_priv in S code",                priv_at_s,  2'b01);
        chk("cur_priv in U code",                priv_at_u,  2'b00);
        chk("cur_priv in S handler",             priv_at_sh, 2'b01);
        chk("cur_priv in M handler",             priv_at_mh, 2'b11);
        chk("cur_priv at end (U)",               cur_priv,   2'b00);
        // S log {scause, sepc, stval, sstatus}
        chk("s0 S load U-page: scause", sl(0,0), 13); chk("s0 sepc", sl(0,1), 32'h104);
        chk("s0 stval = VA",            sl(0,2), 32'h1000); chk("s0 SPP=S", sl(0,3) >> 8 & 1, 1);
        chk("s1 U load S-page: scause", sl(1,0), 13); chk("s1 sepc", sl(1,1), U_CODE + 32'h4);
        chk("s1 stval = VA",            sl(1,2), 32'h4000); chk("s1 SPP=U", sl(1,3) >> 8 & 1, 0);
        chk("s2 U ecall: scause",       sl(2,0), 8);  chk("s2 sepc", sl(2,1), U_CODE + 32'h8);
        chk("s2 stval",                 sl(2,2), 0);  chk("s2 SPP=U", sl(2,3) >> 8 & 1, 0);
        // M log {mcause, mepc, mtval, mstatus}
        chk("m0 U csrr sstatus: mcause", ml(0,0), 2); chk("m0 mepc", ml(0,1), U_CODE + 32'hC);
        chk("m0 mtval = instr",          ml(0,2), U_CSRR_SSTATUS); chk("m0 MPP=U", ml(0,3) >> 11 & 3, 0);
        chk("m1 U store S-page: mcause", ml(1,0), 15); chk("m1 mepc", ml(1,1), U_CODE + 32'h10);
        chk("m1 mtval = VA",             ml(1,2), 32'h4000); chk("m1 MPP=U", ml(1,3) >> 11 & 3, 0);
        $display("CORE SMODE TESTS: %0d passed, %0d failed", pass, fail);
        if (fail == 0) $display("CORE SMODE: PASSED"); else $display("CORE SMODE: FAILED");
        $finish;
    end
endmodule
