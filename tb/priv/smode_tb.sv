// smode_tb.sv — S-mode CSRs, SRET and trap delegation in priv_unit (unit level).
// (a) SRET returns to S (and to U), restoring SIE/SPIE/SPP, pc <= sepc.
// (b) medeleg: ecall-from-U and load page faults go to stvec with scause /
//     sepc / stval / SPP and cur_priv = S; non-delegated traps still go to M;
//     ecall-from-M and traps taken in M never delegate.
// (c) sstatus / sie / sip are masked views; U cannot access S CSRs; SRET is
//     illegal in U and with TSR in S; mideleg routes S interrupts to S.
`timescale 1ns/1ps
module smode_tb;
    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    logic        instr_valid = 0;
    logic [31:0] instr = 32'h13, pc = 0, rs1_data = 0;
    logic        mtip = 0, msip = 0, meip = 0;
    logic        xcpt_valid = 0; logic [31:0] xcpt_cause = 0, xcpt_tval = 0;
    logic        rd_we, redirect, trap, irq_taken, mret, sret, to_s;
    logic [31:0] rd_wdata, redirect_pc, cause_o, satp_o;
    logic        satp_wr, mprv, sum, mxr;
    logic [1:0]  cur_priv, mpp;

    priv_unit dut (.clk, .rst_n, .instr_valid, .instr, .pc, .rs1_data,
                   .mtip, .msip, .meip, .xcpt_valid, .xcpt_cause, .xcpt_tval,
                   .rd_we, .rd_wdata, .redirect, .redirect_pc,
                   .trap, .irq_taken, .mret, .cause_o, .satp_o, .satp_wr_o(satp_wr),
                   .cur_priv, .mstatus_mpp(mpp), .mstatus_mprv(mprv),
                   .mstatus_sum(sum), .mstatus_mxr(mxr), .sret, .trap_to_s(to_s));

    integer pass = 0, fail = 0;
    task automatic check(input string name, input logic [31:0] got, input logic [31:0] exp);
        if (got === exp) pass++;
        else begin fail++; $display("FAIL %s: got %h expected %h", name, got, exp); end
    endtask

    function automatic [31:0] csr_i(input [2:0] f3, input [4:0] rd, input [4:0] rs1, input [11:0] a);
        return {a, rs1, f3, rd, 7'h73};
    endfunction
    localparam [31:0] ECALL = 32'h0000_0073, EBREAK = 32'h0010_0073, MRET = 32'h3020_0073,
                      SRET = 32'h1020_0073, NOP = 32'h0000_0013;
    localparam [2:0] RW = 1, RS = 2, RC = 3;
    localparam [1:0] U = 2'b00, S = 2'b01, M = 2'b11;
    localparam [11:0] SSTATUS = 12'h100, SIE = 12'h104, STVEC = 12'h105, SSCRATCH = 12'h140,
                      SEPC = 12'h141, SCAUSE = 12'h142, STVAL = 12'h143, SIP = 12'h144,
                      MSTATUS = 12'h300, MEDELEG = 12'h302, MIDELEG = 12'h303, MIE = 12'h304,
                      MTVEC = 12'h305, MEPC = 12'h341, MCAUSE = 12'h342, MTVAL = 12'h343,
                      MIP = 12'h344;
    localparam [31:0] MTV = 32'h100, STV = 32'h200;

    logic s_rd_we, s_redirect, s_trap, s_irq, s_mret, s_sret, s_to_s;
    logic [31:0] s_rdata, s_rpc, s_cause;
    task automatic step(input [31:0] i, input [31:0] p, input [31:0] r1 = 0);
        instr = i; pc = p; rs1_data = r1; instr_valid = 1;
        #1;
        s_rd_we = rd_we; s_rdata = rd_wdata; s_redirect = redirect; s_rpc = redirect_pc;
        s_trap = trap; s_irq = irq_taken; s_mret = mret; s_sret = sret; s_cause = cause_o;
        s_to_s = to_s;
        @(posedge clk); #1;
        instr_valid = 0; instr = NOP;
    endtask
    // page fault reported by the pipeline (xcpt port) for the instruction at p
    task automatic xcpt(input [31:0] cause, input [31:0] va, input [31:0] p);
        xcpt_valid = 1; xcpt_cause = cause; xcpt_tval = va; pc = p;
        #1;
        s_trap = trap; s_rpc = redirect_pc; s_to_s = to_s; s_cause = cause_o;
        @(posedge clk); #1;
        xcpt_valid = 0;
    endtask
    task automatic rd(input [11:0] a, output [31:0] v);   // csrr in the current mode
        step(csr_i(RS, 5'd1, 5'd0, a), 32'h0);
        v = s_rdata;
    endtask
    task automatic wr(input [11:0] a, input [31:0] v);    // csrw in the current mode
        step(csr_i(RW, 5'd0, 5'd1, a), 32'h0, v);
    endtask
    // M -> mode m at address a via MRET (must be in M)
    task automatic mret_to(input [1:0] m, input [31:0] a);
        logic [31:0] v;
        rd(MSTATUS, v);
        wr(MSTATUS, (v & ~32'h1800) | {19'b0, m, 11'b0});
        wr(MEPC, a);
        step(MRET, 32'h1F0);
        check("mret_to: cur_priv", cur_priv, m);
    endtask
    // any mode -> M via EBREAK (never delegated in this test)
    task automatic to_m();
        step(EBREAK, 32'h1FC);
        check("to_m: trap to M", {s_trap, s_to_s, cur_priv}, {1'b1, 1'b0, M});
    endtask
    // generic checks of a trap that was just taken into S
    task automatic chk_s_trap(input string n, input [31:0] cause, input [31:0] epc,
                              input [31:0] tval, input [1:0] prev);
        check({n, ": trap"}, s_trap, 1);
        check({n, ": delegated"}, s_to_s, 1);
        check({n, ": pc = stvec"}, s_rpc, STV);
        check({n, ": cur_priv = S"}, cur_priv, S);
        check({n, ": scause"}, dut.u_csr.scause_r, cause);
        check({n, ": sepc"}, dut.u_csr.sepc_r, epc);
        check({n, ": stval"}, dut.u_csr.stval_r, tval);
        check({n, ": SPP"}, dut.u_csr.spp_bit, prev[0]);
        check({n, ": SIE = 0"}, dut.u_csr.sie_bit, 0);
    endtask
    task automatic chk_m_trap(input string n, input [31:0] cause, input [31:0] epc,
                              input [31:0] tval, input [1:0] prev);
        check({n, ": trap"}, s_trap, 1);
        check({n, ": not delegated"}, s_to_s, 0);
        check({n, ": pc = mtvec"}, s_rpc, MTV);
        check({n, ": cur_priv = M"}, cur_priv, M);
        check({n, ": mcause"}, dut.u_csr.mcause_r, cause);
        check({n, ": mepc"}, dut.u_csr.mepc_r, epc);
        check({n, ": mtval"}, dut.u_csr.mtval_r, tval);
        check({n, ": MPP"}, mpp, prev);
    endtask

    logic [31:0] v, ins, mc;
    logic [11:0] a [0:5];
    initial begin a[0] = SIE; a[1] = STVEC; a[2] = SSCRATCH; a[3] = SEPC; a[4] = SCAUSE; a[5] = SIP; end
    initial begin
        #12 rst_n = 1; @(posedge clk); #1;
        wr(MTVEC, MTV); wr(STVEC, STV);
        rd(STVEC, v); check("stvec", v, STV);
        wr(SSCRATCH, 32'h1234_5678); rd(SSCRATCH, v); check("sscratch", v, 32'h1234_5678);

        // ---------- medeleg / mideleg WARL ----------
        wr(MEDELEG, 32'hFFFF_FFFF); rd(MEDELEG, v); check("medeleg mask (no 11)", v, 32'h0000_B3FF);
        wr(MIDELEG, 32'hFFFF_FFFF); rd(MIDELEG, v); check("mideleg mask", v, 32'h0000_0222);
        // ecall from M never delegates, and nor does a page fault taken in M
        step(ECALL, 32'h40);
        chk_m_trap("M ecall, medeleg all-ones", 11, 32'h40, 0, M);
        xcpt(13, 32'hBAD0_0000, 32'h44);
        chk_m_trap("M load PF, medeleg[13]=1", 13, 32'h44, 32'hBAD0_0000, M);
        wr(MEDELEG, 32'h0000_2300);   // delegate 8 (ecall U), 9 (ecall S), 13 (load PF)
        rd(MEDELEG, v); check("medeleg 8,9,13", v, 32'h0000_2300);
        wr(MIDELEG, 32'h0);

        // ---------- (a) SRET returns to S ----------
        mret_to(S, 32'h1000);
        check("S: no MPRV", mprv, 0);
        step(csr_i(6, 5'd0, 5'd2, SSTATUS), 32'h1000);     // csrsi sstatus, SIE (bit 1)
        rd(SSTATUS, v); check("S: sstatus.SIE=1", v, 32'h0000_0002);
        step(ECALL, 32'h1004);                             // ecall from S, delegated
        chk_s_trap("S ecall", 9, 32'h1004, 0, S);
        check("S ecall: SPIE = old SIE", dut.u_csr.spie_bit, 1);
        check("S ecall: mcause untouched", dut.u_csr.mcause_r, 13);
        rd(SSTATUS, v); check("S handler: sstatus SPP|SPIE", v, 32'h0000_0120);
        rd(SEPC, v); wr(SEPC, v + 4);                      // skip the ecall
        step(SRET, 32'h204);
        check("sret flag", s_sret, 1); check("sret redirect", s_redirect, 1);
        check("sret pc = sepc", s_rpc, 32'h1008);
        check("sret: cur_priv = SPP = S", cur_priv, S);
        check("sret: SIE <= SPIE", dut.u_csr.sie_bit, 1);
        check("sret: SPIE <= 1", dut.u_csr.spie_bit, 1);
        check("sret: SPP <= U", dut.u_csr.spp_bit, 0);

        // ---------- (b) SRET to U, delegated ecall-from-U and load page faults ----------
        wr(SEPC, 32'h3000);                                // SPP is U now
        step(SRET, 32'h1010);
        check("sret to U: pc", s_rpc, 32'h3000); check("sret to U: cur_priv", cur_priv, U);
        mc = dut.u_csr.mcause_r;
        step(ECALL, 32'h3000);
        chk_s_trap("U ecall", 8, 32'h3000, 0, U);
        check("U ecall: M state untouched", dut.u_csr.mcause_r, mc);
        check("U ecall: MPP untouched", mpp, U);
        wr(SEPC, 32'h3004); step(SRET, 32'h208);           // back to U
        xcpt(13, 32'h0040_1234, 32'h3004);                 // load page fault in U
        chk_s_trap("U load PF", 13, 32'h3004, 32'h0040_1234, U);
        xcpt(13, 32'h0080_0010, 32'h20C);                  // load page fault in S (handler)
        chk_s_trap("S load PF", 13, 32'h20C, 32'h0080_0010, S);
        // non-delegated: store page fault (15) and illegal instruction (2) go to M
        xcpt(15, 32'h0090_0000, 32'h210);
        chk_m_trap("S store PF (not delegated)", 15, 32'h210, 32'h0090_0000, S);
        mret_to(U, 32'h3008);
        ins = csr_i(RS, 5'd1, 5'd0, SSTATUS);
        step(ins, 32'h3008);                               // (c) U cannot read sstatus
        check("U csrr sstatus: no rd write", s_rd_we, 0);
        chk_m_trap("U csrr sstatus", 2, 32'h3008, ins, U);
        begin : u_scsrs
            for (int k = 0; k < 6; k++) begin
                mret_to(U, 32'h3010 + 4*k);
                ins = csr_i(RS, 5'd1, 5'd0, a[k]);
                step(ins, 32'h3010 + 4*k);
                chk_m_trap($sformatf("U csrr S-CSR %03h", a[k]), 2, 32'h3010 + 4*k, ins, U);
            end
        end
        mret_to(U, 32'h3040);
        step(SRET, 32'h3040);
        chk_m_trap("U sret illegal", 2, 32'h3040, SRET, U);

        // ---------- (c) sstatus / sie / sip masking ----------
        wr(MSTATUS, 32'hFFFF_FFFF);
        rd(MSTATUS, v); check("mstatus all-ones (MPP=M)", v, 32'h004E_19AA);
        rd(SSTATUS, v); check("sstatus view", v, 32'h000C_0122);
        wr(SSTATUS, 32'h0);
        rd(MSTATUS, v); check("sstatus write keeps M bits", v, 32'h0042_1888);
        wr(MSTATUS, 32'h0000_0800);                        // MPP=S, everything else 0
        wr(MIE, 32'h0000_0888); wr(MIDELEG, 32'h0000_0020);
        rd(SIE, v); check("sie = mie & mideleg (0)", v, 0);
        wr(SIE, 32'hFFFF_FFFF);
        rd(MIE, v); check("sie write only delegated bits", v, 32'h0000_08A8);
        rd(SIE, v); check("sie reads STIE", v, 32'h20);
        wr(MIP, 32'h0000_0222);                            // SSIP, STIP, SEIP from M
        rd(MIP, v); check("mip S bits writable from M", v, 32'h222);
        rd(SIP, v); check("sip = mip & mideleg", v, 32'h20);
        wr(MIP, 32'h0);
        wr(SIP, 32'h2);                                    // SSIP not delegated: ignored
        rd(MIP, v); check("sip SSIP write ignored (not delegated)", v, 0);
        wr(MIDELEG, 32'h0000_0022);
        wr(SIP, 32'h2);
        rd(MIP, v); check("sip SSIP write (delegated)", v, 32'h2);
        wr(MIP, 32'h0);
        wr(MIE, 32'h0);

        // ---------- TSR ----------
        wr(MSTATUS, 32'h0040_0800);                        // TSR=1, MPP=S
        wr(MEPC, 32'h4000); step(MRET, 32'h1F0);
        check("in S (TSR)", cur_priv, S);
        step(SRET, 32'h4000);
        chk_m_trap("S sret with TSR=1", 2, 32'h4000, SRET, S);
        wr(MSTATUS, 32'h0);

        // ---------- interrupt delegation (STI via mideleg) ----------
        wr(MIDELEG, 32'h20); wr(MIE, 32'h0000_00A0);       // STIE + MTIE
        wr(MIP, 32'h20);                                   // STIP pending
        step(NOP, 32'h300); check("M: delegated STI not taken", s_trap, 0);
        mret_to(S, 32'h5000);                              // SIE = 0
        step(NOP, 32'h5000); check("S, SIE=0: STI masked", s_trap, 0);
        step(csr_i(6, 5'd0, 5'd2, SSTATUS), 32'h5004);     // SIE=1
        step(NOP, 32'h5008);
        check("S, SIE=1: STI taken", s_irq, 1);
        chk_s_trap("S STI", 32'h8000_0005, 32'h5008, 0, S);
        // vectored stvec
        wr(STVEC, STV | 1);
        rd(SEPC, v); step(SRET, 32'h20C);                  // back to S, SIE=1
        step(NOP, 32'h5008);
        check("vectored stvec: STI -> base + 4*5", s_rpc, STV + 32'h14);
        check("vectored: delegated", s_to_s, 1);
        wr(STVEC, STV);
        // in U the S interrupt is taken whatever SIE says
        wr(SSTATUS, 32'h0);                                // SIE=0, SPIE=0, SPP=U
        wr(SEPC, 32'h6000); step(SRET, 32'h210);
        check("U (SIE=0 after sret? SPIE=0)", {cur_priv, dut.u_csr.sie_bit}, {U, 1'b0});
        step(NOP, 32'h6000);
        chk_s_trap("U STI (SIE=0)", 32'h8000_0005, 32'h6000, 0, U);
        // M interrupt beats S, taken in M from S even with mstatus.MIE = 0
        mtip = 1;
        step(NOP, 32'h214);
        chk_m_trap("S: MTI over STI (MIE=0)", 32'h8000_0007, 32'h214, 0, S);
        mtip = 0;
        wr(MIP, 32'h0); wr(MIE, 32'h0);

        $display("SMODE TESTS: %0d passed, %0d failed", pass, fail);
        if (fail == 0) $display("SMODE: PASSED"); else $display("SMODE: FAILED");
        $finish;
    end
endmodule
