// priv_modes_tb.sv — M/S/U privilege modes in priv_unit (unit level).
// Checks: reset in M; MPP WARL; MRET into U and S (cur_priv = MPP, MPP <= U);
// M-only CSR access from U/S -> illegal (mcause 2, mtval = instr, mepc, MPP =
// previous mode, cur_priv = M); S-level CSR (satp) from U -> illegal, from S
// legal; user counter from U legal; MRET from U -> illegal; ECALL cause 8/9/11;
// M interrupts taken in U even with mstatus.MIE = 0, masked in M; MPRV/SUM/MXR
// exported and MPRV cleared by an MRET to a lower mode; SFENCE.VMA legal in
// S/M (one-cycle sfence pulse), illegal in U.
`timescale 1ns/1ps
module priv_modes_tb;
    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    logic        instr_valid = 0;
    logic [31:0] instr = 32'h13, pc = 0, rs1_data = 0;
    logic        mtip = 0, msip = 0, meip = 0;
    logic        rd_we, redirect, trap, irq_taken, mret;
    logic [31:0] rd_wdata, redirect_pc, cause_o, satp_o;
    logic        satp_wr, mprv, sum, mxr;
    logic [1:0]  cur_priv, mpp;
    logic        sfence;

    priv_unit dut (.clk, .rst_n, .instr_valid, .instr, .pc, .rs1_data,
                   .mtip, .msip, .meip, .rd_we, .rd_wdata, .redirect, .redirect_pc,
                   .trap, .irq_taken, .mret, .cause_o, .satp_o, .satp_wr_o(satp_wr),
                   .cur_priv, .mstatus_mpp(mpp), .mstatus_mprv(mprv),
                   .mstatus_sum(sum), .mstatus_mxr(mxr), .sfence);

    integer pass = 0, fail = 0;
    task automatic check(input string name, input logic [31:0] got, input logic [31:0] exp);
        if (got === exp) pass++;
        else begin fail++; $display("FAIL %s: got %h expected %h", name, got, exp); end
    endtask

    function automatic [31:0] csr_i(input [2:0] f3, input [4:0] rd, input [4:0] rs1, input [11:0] a);
        return {a, rs1, f3, rd, 7'h73};
    endfunction
    localparam [31:0] ECALL = 32'h0000_0073, MRET = 32'h3020_0073, NOP = 32'h0000_0013;
    localparam [2:0] RW = 1, RS = 2, RC = 3;
    localparam [1:0] U = 2'b00, S = 2'b01, M = 2'b11;
    localparam [11:0] MSTATUS = 12'h300, MIE = 12'h304, MTVEC = 12'h305, MEPC = 12'h341,
                      MCAUSE = 12'h342, MTVAL = 12'h343, SATP = 12'h180, CYCLE = 12'hC00;

    logic s_rd_we, s_redirect, s_trap, s_irq, s_mret; logic [31:0] s_rdata, s_rpc, s_cause;
    logic s_sfence;
    task automatic step(input [31:0] i, input [31:0] p, input [31:0] r1 = 0);
        instr = i; pc = p; rs1_data = r1; instr_valid = 1;
        #1;
        s_rd_we = rd_we; s_rdata = rd_wdata; s_redirect = redirect; s_rpc = redirect_pc;
        s_trap = trap; s_irq = irq_taken; s_mret = mret; s_cause = cause_o;
        s_sfence = sfence;
        @(posedge clk); #1;
        instr_valid = 0; instr = NOP;
    endtask
    // CSR read only legal from M (the handler) -> used after traps
    task automatic rdcsr(input [11:0] a, output [31:0] v);
        step(csr_i(RS, 5'd1, 5'd0, a), 32'h0);
        v = s_rdata;
    endtask
    task automatic wrcsr(input [11:0] a, input [31:0] v);
        step(csr_i(RW, 5'd0, 5'd1, a), 32'h0, v);
    endtask
    // check the trap that was just taken, from the handler (M-mode)
    task automatic chk_trap(input string n, input [31:0] cause, input [31:0] epc,
                            input [31:0] tval, input [1:0] prev);
        logic [31:0] v;
        check({n, ": trap"}, s_trap, 1);
        check({n, ": -> mtvec"}, s_rpc, 32'h100);
        check({n, ": cur_priv=M"}, cur_priv, M);
        check({n, ": MPP=prev mode"}, mpp, prev);
        rdcsr(MCAUSE, v); check({n, ": mcause"}, v, cause);
        rdcsr(MEPC, v);   check({n, ": mepc"}, v, epc);
        rdcsr(MTVAL, v);  check({n, ": mtval"}, v, tval);
        rdcsr(MSTATUS, v); check({n, ": mstatus.MPP"}, v[12:11], prev);
    endtask
    // from M: MRET into mode m at address a
    task automatic enter(input [1:0] m, input [31:0] a);
        logic [31:0] v;
        rdcsr(MSTATUS, v);
        wrcsr(MSTATUS, (v & ~32'h1800) | {19'b0, m, 11'b0});
        wrcsr(MEPC, a);
        step(MRET, 32'h1F0);
        check("mret redirect", s_mret && s_redirect, 1);
        check("mret target", s_rpc, a);
        check("mret: cur_priv = MPP", cur_priv, m);
        check("mret: MPP <- U", mpp, U);
    endtask

    logic [31:0] v, ins;
    initial begin
        #12 rst_n = 1; @(posedge clk); #1;
        check("reset: cur_priv=M", cur_priv, M);
        rdcsr(MSTATUS, v); check("reset: mstatus MPP=M", v, 32'h0000_1800);
        rdcsr(12'h301, v); check("misa I,M,S,U", v, 32'h4014_1100);
        wrcsr(MTVEC, 32'h100);

        // ---- MPP WARL ----
        wrcsr(MSTATUS, 32'h0000_1000); rdcsr(MSTATUS, v); check("MPP=10 clamps to S", v[12:11], S);
        wrcsr(MSTATUS, 32'h0000_0000); rdcsr(MSTATUS, v); check("MPP=U", v[12:11], U);
        wrcsr(MSTATUS, 32'h0000_0800); rdcsr(MSTATUS, v); check("MPP=S", v[12:11], S);
        wrcsr(MSTATUS, 32'h0000_1800); rdcsr(MSTATUS, v); check("MPP=M", v[12:11], M);
        // ECALL from M still 11, MPP = M
        step(ECALL, 32'h40);
        chk_trap("ecall M", 11, 32'h40, 0, M);

        // ---- M -> U, illegal M-CSR access from U ----
        enter(U, 32'h1000);
        ins = csr_i(RS, 5'd1, 5'd0, MSTATUS);           // csrr x1, mstatus
        step(ins, 32'h1000);
        check("U csrr mstatus: no rd write", s_rd_we, 0);
        chk_trap("U csrr mstatus", 2, 32'h1000, ins, U);
        enter(U, 32'h1004);
        ins = csr_i(RS, 5'd1, 5'd0, SATP);              // S-level CSR from U
        step(ins, 32'h1004);
        chk_trap("U csrr satp", 2, 32'h1004, ins, U);
        enter(U, 32'h1008);
        step(csr_i(RS, 5'd1, 5'd0, CYCLE), 32'h1008);   // user counter: legal in U
        check("U csrr cycle: no trap", s_trap, 0); check("U csrr cycle: rd write", s_rd_we, 1);
        check("still U", cur_priv, U);
        step(MRET, 32'h100C);
        check("U mret: not an mret", s_mret, 0);
        chk_trap("U mret", 2, 32'h100C, MRET, U);
        enter(U, 32'h1010);
        step(ECALL, 32'h1010);
        chk_trap("U ecall", 8, 32'h1010, 0, U);

        // ---- M -> S ----
        enter(S, 32'h2000);
        step(csr_i(RW, 5'd2, 5'd1, SATP), 32'h2000, 32'h8000_0002);   // satp legal in S
        check("S csrrw satp: no trap", s_trap, 0);
        check("S satp written", satp_o, 32'h8000_0002); check("still S", cur_priv, S);
        ins = csr_i(RS, 5'd1, 5'd0, MSTATUS);
        step(ins, 32'h2004);
        chk_trap("S csrr mstatus", 2, 32'h2004, ins, S);
        enter(S, 32'h2008);
        ins = csr_i(RW, 5'd0, 5'd1, MEPC);
        step(ins, 32'h2008, 32'hDEAD_0000);
        chk_trap("S csrw mepc", 2, 32'h2008, ins, S);
        enter(S, 32'h200C);
        step(ECALL, 32'h200C);
        chk_trap("S ecall", 9, 32'h200C, 0, S);
        enter(S, 32'h2010);
        step(MRET, 32'h2010);
        chk_trap("S mret", 2, 32'h2010, MRET, S);

        // ---- interrupts: M-mode needs MIE, U/S always enabled ----
        wrcsr(MIE, 32'h80);                             // MTIE; mstatus.MIE = 0
        mtip = 1;
        step(NOP, 32'h300); check("M, MIE=0: timer masked", s_trap, 0);
        enter(U, 32'h3000);
        step(NOP, 32'h3000);
        check("U, MIE=0: timer taken", s_irq, 1);
        chk_trap("U timer irq", 32'h8000_0007, 32'h3000, 0, U);
        step(NOP, 32'h104); check("back in M: masked again", s_trap, 0);
        enter(S, 32'h3004);
        step(NOP, 32'h3004);
        chk_trap("S timer irq", 32'h8000_0007, 32'h3004, 0, S);
        mtip = 0;
        wrcsr(MIE, 32'h0);

        // ---- MPRV / SUM / MXR ----
        rdcsr(MSTATUS, v);
        wrcsr(MSTATUS, v | 32'h000E_0000 | 32'h0000_0800);   // MPRV|SUM|MXR, MPP=S
        check("MPRV out", mprv, 1); check("SUM out", sum, 1); check("MXR out", mxr, 1);
        check("MPP out = S", mpp, S);
        rdcsr(MSTATUS, v); check("mstatus bits 19:17", v[19:17], 3'b111);
        wrcsr(MEPC, 32'h4000);
        step(MRET, 32'h1F0);
        check("mret to S clears MPRV", mprv, 0); check("SUM kept", sum, 1);
        check("in S", cur_priv, S);

        // ---- SFENCE.VMA rs1, rs2 (funct7=0001001): legal in S/M, illegal in U ----
        ins = {7'b0001001, 5'd6, 5'd5, 3'b000, 5'd0, 7'h73};   // sfence.vma x5, x6
        step(ins, 32'h4000);
        check("S sfence.vma: no trap", s_trap, 0); check("S sfence pulse", s_sfence, 1);
        check("S sfence: no rd write", s_rd_we, 0); check("still S", cur_priv, S);
        step(ECALL, 32'h4004);
        chk_trap("S ecall (after sfence)", 9, 32'h4004, 0, S);
        step({7'b0001001, 5'd0, 5'd0, 3'b000, 5'd0, 7'h73}, 32'h108);  // sfence.vma in M
        check("M sfence.vma: no trap", s_trap, 0); check("M sfence pulse", s_sfence, 1);
        step(NOP, 32'h10C); check("sfence pulse is one cycle", s_sfence, 0);
        enter(U, 32'h5000);
        step(ins, 32'h5000);
        check("U sfence.vma: no pulse", s_sfence, 0);
        chk_trap("U sfence.vma", 2, 32'h5000, ins, U);

        $display("PRIV MODES TESTS: %0d passed, %0d failed", pass, fail);
        if (fail == 0) $display("PRIV MODES: PASSED"); else $display("PRIV MODES: FAILED");
        $finish;
    end
endmodule
