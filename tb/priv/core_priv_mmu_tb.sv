// core_priv_mmu_tb.sv — privilege modes in the integrated core (core_top,
// USE_MMU=1, priv_mode=2'b11 = architectural privilege, no override).
// satp = 0x80000002 (Sv32, root PA 0x2000) is enabled from M-mode:
//   VA 0x1000 -> PA 0x5000, U=1 page;   VA 0x4000 -> PA 0x6000, U=0 (S) page.
// Program (assembled below):
//   M : loads bypass the MMU (VA 0x1000 -> PA 0x1000, VA 0x4000 -> PA 0x4000);
//       MPRV=1 with MPP=S translates an M-mode load (VA 0x4000 -> PA 0x6000).
//   MRET -> S : S page translates; U page from S (SUM=0) -> load page fault;
//       satp readable in S; ECALL (cause 9) asks the handler to drop to U.
//   U : U page translates; S page from U -> load page fault; csrr mstatus ->
//       illegal (2); ECALL (cause 8) returns to U.
// The M-mode handler logs {mcause, mepc, mtval, mstatus} for every trap.
`timescale 1ns/1ps
module core_priv_mmu_tb;
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
    localparam int S_CODE = 32'h100, U_CODE = 32'h180, HANDLER = 32'h200, LOG = 32'h700;
    localparam [31:0] U_CSRR_MSTATUS = {MSTATUS, 5'd0, 3'd2, 5'd12, 7'h73};

    int n;
    task automatic org(input int a); n = a >> 2; endtask
    task automatic E(input [31:0] w); mem[n] = w; n++; endtask

    initial begin
        for (int k = 0; k < 8192; k++) mem[k] = 32'h0000_0013;
        // ---- M-mode main @0 ----
        org(0);
        E(Addi(1, 0, HANDLER)); E(Csr(1, 0, MTVEC, 1));
        E(Lui(2, 1)); E(Lui(3, 4));                        // x2 = 0x1000, x3 = 0x4000
        E(Addi(28, 0, LOG));
        E(Lui(29, 2)); E(Addi(29, 29, 12'h800));           // x29 = 0x2000 - 0x800 = 0x1800
        E(Addi(9, 0, 12'h5A5)); E(Addi(11, 0, 12'h5A5)); E(Addi(12, 0, 12'h5A5));
        E(Lui(1, 20'h80000)); E(Addi(1, 1, 2)); E(Csr(1, 0, SATP, 1));  // satp = Sv32, root 0x2000
        E(Lw(5, 2, 0));                                    // M: bypass -> PA 0x1000
        E(Lw(6, 3, 0));                                    // M: bypass -> PA 0x4000
        E(Lui(1, 1)); E(Csr(3, 0, MSTATUS, 1));            // MPP: M -> S (clear bit 12)
        E(Lui(13, 20'h20)); E(Csr(2, 0, MSTATUS, 13));     // MPRV = 1
        E(Lw(7, 3, 0));                                    // M+MPRV, MPP=S -> PA 0x6000
        E(Csr(3, 0, MSTATUS, 13));                         // MPRV = 0
        E(Lw(15, 3, 0));                                   // bypass again -> PA 0x4000
        E(Addi(1, 0, S_CODE)); E(Csr(1, 0, MEPC, 1));
        E(MRET);                                           // -> S @ S_CODE
        // ---- S-mode @0x100 ----
        org(S_CODE);
        E(Lw(8, 3, 0));                                    // 0x100 S page -> PA 0x6000
        E(Lw(9, 2, 0));                                    // 0x104 U page from S -> PF 13
        E(Csr(2, 16, SATP, 0));                            // 0x108 csrr satp (legal in S)
        E(Addi(30, 0, U_CODE));                            // 0x10C
        E(Addi(31, 0, 1));                                 // 0x110 request: drop to U
        E(ECALL);                                          // 0x114 cause 9
        // ---- U-mode @0x180 ----
        org(U_CODE);
        E(Lw(10, 2, 0));                                   // 0x180 U page -> PA 0x5000
        E(Lw(11, 3, 0));                                   // 0x184 S page from U -> PF 13
        E(U_CSRR_MSTATUS);                                 // 0x188 csrr x12, mstatus -> 2
        E(ECALL);                                          // 0x18C cause 8
        E(Addi(17, 0, 1));                                 // 0x190 back in U
        E(Jal(0, 0));                                      // 0x194 end
        // ---- M-mode trap handler @0x200 ----
        org(HANDLER);
        E(Csr(2, 25, MCAUSE, 0)); E(Csr(2, 26, MEPC, 0));
        E(Csr(2, 27, MTVAL, 0));  E(Csr(2, 23, MSTATUS, 0));
        E(Sw(25, 28, 0)); E(Sw(26, 28, 4)); E(Sw(27, 28, 8)); E(Sw(23, 28, 12));
        E(Addi(28, 28, 16)); E(Addi(24, 24, 1));
        E(Beq(31, 0, 13'd20));                             // no request -> SKIP
        E(Csr(3, 0, MSTATUS, 29));                         // MPP = U
        E(Csr(1, 0, MEPC, 30));                            // mepc = U_CODE
        E(Addi(31, 0, 0));
        E(Jal(0, 21'd12));                                 // -> RET
        E(Addi(26, 26, 4)); E(Csr(1, 0, MEPC, 26));        // SKIP: mepc += 4
        E(MRET);                                           // RET
        // ---- page tables / data ----
        mem[32'h2000 >> 2] = 32'h0000_0C01;   // L1[0] -> L0 @ PA 0x3000
        mem[32'h3004 >> 2] = 32'h0000_14D7;   // VA 0x1000 -> PPN 5, V|R|W|U|A|D
        mem[32'h3010 >> 2] = 32'h0000_18C7;   // VA 0x4000 -> PPN 6, V|R|W|A|D (S page)
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
        .priv_mode(2'b11), .mmu_fault, .cur_priv);

    // privilege seen when specific instructions execute
    logic [1:0] priv_at_s = 2'bxx, priv_at_u = 2'bxx, priv_at_h = 2'bxx, priv_at_m = 2'bxx;
    always @(posedge clk) if (rst_n && dut.valid_ex) begin
        if (dut.pc_ex == 32'h14)      priv_at_m = cur_priv;
        if (dut.pc_ex == S_CODE)      priv_at_s = cur_priv;
        if (dut.pc_ex == U_CODE)      priv_at_u = cur_priv;
        if (dut.pc_ex == HANDLER)     priv_at_h = cur_priv;
        if (dut.p_trap) $display("  trap @pc %08h priv=%0d: mcause=%0d", dut.pc_ex, cur_priv, dut.p_cause);
    end

    int pass = 0, fail = 0;
    task automatic chk(string name, logic [31:0] got, logic [31:0] exp);
        if (got !== exp) begin fail++; $display("  FAIL %-36s got %08h exp %08h", name, got, exp); end
        else begin pass++; $display("  ok   %-36s = %08h", name, got); end
    endtask
    function automatic [31:0] lg(input int e, input int w); return mem[(LOG >> 2) + 4*e + w]; endfunction
    int cyc = 0;
    initial begin
        #22 rst_n = 1;
        while (!(dut.regs[17] == 1 && dut.pc_ex == 32'h194) && cyc < 3000) begin @(posedge clk); cyc++; end
        repeat (5) @(posedge clk);
        $display("core priv/MMU test: %0d cycles", cyc);
        chk("M: bypass VA 0x1000 (x5)",            dut.regs[5],  32'h1111_1111);
        chk("M: bypass VA 0x4000 (x6)",            dut.regs[6],  32'h4444_4444);
        chk("M+MPRV(MPP=S): VA 0x4000->0x6000 (x7)", dut.regs[7], 32'h6666_6666);
        chk("M, MPRV=0: bypass again (x15)",       dut.regs[15], 32'h4444_4444);
        chk("S: S page VA 0x4000->0x6000 (x8)",    dut.regs[8],  32'h6666_6666);
        chk("S: U page faulted, x9 untouched",     dut.regs[9],  32'h5A5);
        chk("S: csrr satp (x16)",                  dut.regs[16], 32'h8000_0002);
        chk("U: U page VA 0x1000->0x5000 (x10)",   dut.regs[10], 32'h5555_5555);
        chk("U: S page faulted, x11 untouched",    dut.regs[11], 32'h5A5);
        chk("U: csrr mstatus trapped, x12 kept",   dut.regs[12], 32'h5A5);
        chk("U: resumed after ecall (x17)",        dut.regs[17], 1);
        chk("traps taken (x24)",                   dut.regs[24], 5);
        chk("cur_priv in M main",                  priv_at_m, 2'b11);
        chk("cur_priv in S code",                  priv_at_s, 2'b01);
        chk("cur_priv in U code",                  priv_at_u, 2'b00);
        chk("cur_priv in handler",                 priv_at_h, 2'b11);
        chk("cur_priv at end (U)",                 cur_priv,  2'b00);
        // trap log {mcause, mepc, mtval, mstatus.MPP}
        chk("t0 S load U-page: mcause",  lg(0,0), 13); chk("t0 mepc", lg(0,1), 32'h104);
        chk("t0 mtval",                  lg(0,2), 32'h1000); chk("t0 MPP=S", lg(0,3) >> 11 & 3, 1);
        chk("t1 S ecall: mcause",        lg(1,0), 9);  chk("t1 mepc", lg(1,1), 32'h114);
        chk("t1 mtval",                  lg(1,2), 0);  chk("t1 MPP=S", lg(1,3) >> 11 & 3, 1);
        chk("t2 U load S-page: mcause",  lg(2,0), 13); chk("t2 mepc", lg(2,1), 32'h184);
        chk("t2 mtval",                  lg(2,2), 32'h4000); chk("t2 MPP=U", lg(2,3) >> 11 & 3, 0);
        chk("t3 U csrr mstatus: mcause", lg(3,0), 2);  chk("t3 mepc", lg(3,1), 32'h188);
        chk("t3 mtval = instr",          lg(3,2), U_CSRR_MSTATUS); chk("t3 MPP=U", lg(3,3) >> 11 & 3, 0);
        chk("t4 U ecall: mcause",        lg(4,0), 8);  chk("t4 mepc", lg(4,1), 32'h18C);
        chk("t4 MPP=U",                  lg(4,3) >> 11 & 3, 0);
        $display("CORE PRIV MMU TESTS: %0d passed, %0d failed", pass, fail);
        if (fail == 0) $display("CORE PRIV MMU: PASSED"); else $display("CORE PRIV MMU: FAILED");
        $finish;
    end
endmodule
