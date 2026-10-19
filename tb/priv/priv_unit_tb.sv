// priv_unit_tb.sv — directed test for rtl/priv (csr_file + priv_unit).
// Drives one instruction per cycle into priv_unit and checks CSR results,
// trap redirects, mcause/mepc/mtval for ECALL, EBREAK, illegal instruction,
// and the machine timer interrupt (direct + vectored mtvec).
`timescale 1ns/1ps
module priv_unit_tb;
    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    logic        instr_valid = 0;
    logic [31:0] instr = 32'h13, pc = 0, rs1_data = 0;
    logic        mtip = 0, msip = 0, meip = 0;
    logic        rd_we, redirect, trap, irq_taken, mret;
    logic [31:0] rd_wdata, redirect_pc, cause_o;
    logic [31:0] satp_o;
    logic        satp_wr;

    priv_unit dut (.clk, .rst_n, .instr_valid, .instr, .pc, .rs1_data,
                   .mtip, .msip, .meip, .rd_we, .rd_wdata, .redirect, .redirect_pc,
                   .trap, .irq_taken, .mret, .cause_o,
                   .satp_o, .satp_wr_o(satp_wr));

    integer pass = 0, fail = 0;
    task automatic check(input string name, input logic [31:0] got, input logic [31:0] exp);
        if (got === exp) pass++;
        else begin fail++; $display("FAIL %s: got %h expected %h", name, got, exp); end
    endtask

    // encoders
    function automatic [31:0] csr_i(input [2:0] f3, input [4:0] rd, input [4:0] rs1, input [11:0] a);
        return {a, rs1, f3, rd, 7'h73};
    endfunction
    localparam [31:0] ECALL = 32'h0000_0073, EBREAK = 32'h0010_0073, MRET = 32'h3020_0073,
                      NOP = 32'h0000_0013, BAD = 32'hFFFF_FFFF;
    localparam [2:0] RW = 1, RS = 2, RC = 3, RWI = 5, RSI = 6, RCI = 7;

    // captured outputs of the last step
    logic s_rd_we, s_redirect, s_trap, s_irq, s_mret; logic [31:0] s_rdata, s_rpc, s_cause;
    logic s_satp_wr;

    // present one instruction for one cycle, sample combinational outputs, commit at edge
    task automatic step(input [31:0] i, input [31:0] p, input [31:0] r1 = 0);
        instr = i; pc = p; rs1_data = r1; instr_valid = 1;
        #1;
        s_rd_we = rd_we; s_rdata = rd_wdata; s_redirect = redirect; s_rpc = redirect_pc;
        s_trap = trap; s_irq = irq_taken; s_mret = mret; s_cause = cause_o;
        s_satp_wr = satp_wr;
        @(posedge clk); #1;
        instr_valid = 0; instr = NOP;
    endtask
    // read a CSR via csrrs rd=x1, rs1=x0 and return value
    task automatic rdcsr(input [11:0] a, output [31:0] v);
        step(csr_i(RS, 5'd1, 5'd0, a), 32'h0);
        v = s_rdata;
    endtask

    logic [31:0] v;
    initial begin
        #12 rst_n = 1; @(posedge clk); #1;

        // ---------- basic CSR ops ----------
        rdcsr(12'h301, v); check("misa", v, 32'h4000_1100);
        rdcsr(12'hF14, v); check("mhartid", v, 0);
        check("csrrs rd_we", s_rd_we, 1); check("csr no trap", s_trap, 0);
        rdcsr(12'h300, v); check("mstatus reset (MPP=M)", v, 32'h0000_1800);

        step(csr_i(RW, 5'd0, 5'd2, 12'h305), 0, 32'h0000_0100);   // csrrw x0, mtvec, x2
        check("csrrw rd=x0 no rd write", s_rd_we, 0);
        rdcsr(12'h305, v); check("mtvec", v, 32'h100);

        step(csr_i(RW, 5'd3, 5'd2, 12'h340), 0, 32'hA5A5_0000);   // mscratch = A5A50000
        check("csrrw old value", s_rdata, 0);
        step(csr_i(RS, 5'd3, 5'd2, 12'h340), 0, 32'h0000_00FF);   // set bits
        check("csrrw->old", s_rdata, 32'hA5A5_0000);
        step(csr_i(RC, 5'd3, 5'd2, 12'h340), 0, 32'hA000_000F);   // clear bits
        check("csrrs->old", s_rdata, 32'hA5A5_00FF);
        rdcsr(12'h340, v); check("csrrc result", v, 32'h05A5_00F0);
        step(csr_i(RS, 5'd3, 5'd0, 12'h340), 0, 32'hFFFF_FFFF);   // rs1=x0: no write
        rdcsr(12'h340, v); check("csrrs rs1=x0 no write", v, 32'h05A5_00F0);
        step(csr_i(RWI, 5'd3, 5'd21, 12'h340), 0);                 // csrrwi 21
        rdcsr(12'h340, v); check("csrrwi", v, 21);
        step(csr_i(RSI, 5'd0, 5'd8, 12'h340), 0);                  // |= 8
        step(csr_i(RCI, 5'd0, 5'd1, 12'h340), 0);                  // &= ~1
        rdcsr(12'h340, v); check("csrrsi/csrrci", v, 28);
        step(csr_i(RW, 5'd0, 5'd2, 12'h341), 0, 32'h0000_1237);   // mepc low bits drop
        rdcsr(12'h341, v); check("mepc align", v, 32'h1234);
        step(csr_i(RW, 5'd0, 5'd2, 12'h304), 0, 32'hFFFF_FFFF);
        rdcsr(12'h304, v); check("mie WARL mask", v, 32'h888);
        step(csr_i(RW, 5'd0, 5'd0, 12'h304), 0);                  // mie = 0
        rdcsr(12'hB00, v); check("mcycle running", v > 0, 1);
        rdcsr(12'hC02, v); check("instret alias nonzero", v > 0, 1);

        // ---------- ECALL -> handler -> MRET ----------
        step(csr_i(RSI, 5'd0, 5'd8, 12'h300), 0);                  // MIE=1
        step(ECALL, 32'h40);
        check("ecall trap", s_trap, 1); check("ecall redirect", s_redirect, 1);
        check("ecall target=mtvec", s_rpc, 32'h100);
        rdcsr(12'h342, v); check("ecall mcause", v, 11);
        rdcsr(12'h341, v); check("ecall mepc", v, 32'h40);
        rdcsr(12'h343, v); check("ecall mtval", v, 0);
        rdcsr(12'h300, v); check("trap: MIE=0 MPIE=1", v, 32'h0000_1880);
        // handler: mepc += 4
        step(csr_i(RW, 5'd0, 5'd2, 12'h341), 32'h104, 32'h44);
        step(MRET, 32'h108);
        check("mret flag", s_mret, 1); check("mret redirect", s_redirect, 1);
        check("mret target", s_rpc, 32'h44); check("mret not trap", s_trap, 0);
        rdcsr(12'h300, v); check("mret: MIE restored", v, 32'h0000_1888);

        // ---------- illegal instructions ----------
        step(BAD, 32'h80);
        check("illegal trap", s_trap, 1); check("illegal target", s_rpc, 32'h100);
        rdcsr(12'h342, v); check("illegal mcause", v, 2);
        rdcsr(12'h341, v); check("illegal mepc", v, 32'h80);
        rdcsr(12'h343, v); check("illegal mtval", v, BAD);
        step(MRET, 32'h100);
        step(csr_i(RS, 5'd1, 5'd0, 12'h7FF), 32'h84);              // unknown CSR
        check("unknown csr trap", s_trap, 1); check("unknown csr no rd", s_rd_we, 0);
        rdcsr(12'h342, v); check("unknown csr mcause", v, 2);
        rdcsr(12'h343, v); check("unknown csr mtval", v, csr_i(RS, 5'd1, 5'd0, 12'h7FF));
        step(MRET, 32'h100);
        step(csr_i(RW, 5'd0, 5'd2, 12'hF14), 32'h88, 32'h5);      // write read-only
        check("write mhartid traps", s_trap, 1);
        rdcsr(12'h341, v); check("ro write mepc", v, 32'h88);
        step(MRET, 32'h100);
        step(32'h1050_0073 | (5'd1 << 7), 32'h8C);                 // WFI with rd!=0 -> illegal
        check("bad SYSTEM encoding traps", s_trap, 1);
        step(MRET, 32'h100);
        step(32'h1050_0073, 32'h90); check("wfi is nop", s_trap, 0);

        // ---------- EBREAK ----------
        step(EBREAK, 32'h94);
        check("ebreak trap", s_trap, 1);
        rdcsr(12'h342, v); check("ebreak mcause", v, 3);
        rdcsr(12'h343, v); check("ebreak mtval=pc", v, 32'h94);
        step(MRET, 32'h100);

        // ---------- machine timer interrupt ----------
        mtip = 1;
        step(NOP, 32'h200);
        check("mtip masked by mie (MTIE=0)", s_trap, 0);
        rdcsr(12'h344, v); check("mip.MTIP set", v, 32'h80);
        step(csr_i(RCI, 5'd0, 5'd8, 12'h300), 0);                  // MIE=0
        step(csr_i(RS, 5'd0, 5'd1, 12'h304), 0, 32'h80);           // MTIE=1
        step(NOP, 32'h204);
        check("mtip masked by mstatus.MIE=0", s_trap, 0);
        step(csr_i(RSI, 5'd0, 5'd8, 12'h300), 32'h208);            // MIE=1 (this instr executes)
        check("csr instr that enables MIE executes", s_trap, 0);
        step(32'h00A00093, 32'h20C);                               // addi: interrupted before exec
        check("irq taken", s_irq, 1); check("irq trap", s_trap, 1);
        check("irq target direct", s_rpc, 32'h100);
        check("irq cause out", s_cause, 32'h8000_0007);
        step(NOP, 32'h100);
        check("no re-entry while MIE=0", s_trap, 0);
        rdcsr(12'h342, v); check("irq mcause", v, 32'h8000_0007);
        rdcsr(12'h341, v); check("irq mepc", v, 32'h20C);
        rdcsr(12'h343, v); check("irq mtval", v, 0);
        rdcsr(12'h300, v); check("irq: MIE=0 MPIE=1", v, 32'h0000_1880);
        mtip = 0;                                                  // handler acks timer
        step(MRET, 32'h110);
        check("irq mret target", s_rpc, 32'h20C);
        step(32'h00A00093, 32'h20C); check("resumes, no trap", s_trap, 0);

        // ---------- vectored mtvec ----------
        step(csr_i(RW, 5'd0, 5'd2, 12'h305), 0, 32'h0000_0101);
        rdcsr(12'h305, v); check("mtvec vectored", v, 32'h101);
        step(ECALL, 32'h300); check("vectored: exception -> base", s_rpc, 32'h100);
        step(MRET, 32'h100);
        mtip = 1;
        step(NOP, 32'h304); check("vectored: timer -> base+0x1C", s_rpc, 32'h11C);
        step(csr_i(RS, 5'd0, 5'd1, 12'h304), 32'h11C, 32'h888);   // in handler (MIE=0): enable all
        step(MRET, 32'h120);
        // priority: external > software > timer
        meip = 1; msip = 1;
        step(NOP, 32'h308); check("priority MEI", s_cause, 32'h8000_000B);
        check("vectored MEI target", s_rpc, 32'h12C);
        step(MRET, 32'h12C); meip = 0;
        step(NOP, 32'h308); check("priority MSI", s_cause, 32'h8000_0003);
        step(MRET, 32'h10C); msip = 0;
        step(NOP, 32'h308); check("then MTI", s_cause, 32'h8000_0007);
        mtip = 0;
        step(MRET, 32'h11C);
        step(NOP, 32'h308); check("quiet", s_trap, 0);

        // ---------- satp (0x180, Sv32: MODE[31], ASID[30:22]=0 WARL, PPN[21:0]) ----------
        rdcsr(12'h180, v); check("satp reset", v, 32'h0); check("satp read no trap", s_trap, 0);
        check("satp_o reset", satp_o, 32'h0); check("satp read: no write pulse", s_satp_wr, 0);
        step(csr_i(RW, 5'd1, 5'd1, 12'h180), 32'h400, 32'hFFFF_FFFF);
        check("csrrw satp old", s_rdata, 32'h0); check("satp write pulse", s_satp_wr, 1);
        rdcsr(12'h180, v); check("satp WARL (ASID=0)", v, 32'h803F_FFFF);
        check("satp_o", satp_o, 32'h803F_FFFF);
        step(csr_i(RC, 5'd0, 5'd1, 12'h180), 32'h404, 32'h8000_0000);   // clear MODE
        rdcsr(12'h180, v); check("satp csrrc MODE", v, 32'h003F_FFFF);
        step(csr_i(RW, 5'd0, 5'd1, 12'h180), 32'h408, 32'h8000_0002);
        rdcsr(12'h180, v); check("satp Sv32 root PPN 2", v, 32'h8000_0002);
        step(csr_i(RWI, 5'd0, 5'd0, 12'h180), 32'h40C);                 // csrwi satp, 0
        check("csrwi satp pulse", s_satp_wr, 1);
        rdcsr(12'h180, v); check("satp csrwi 0", v, 32'h0);

        $display("PRIV TESTS: %0d passed, %0d failed", pass, fail);
        if (fail == 0) $display("PRIV: PASSED"); else $display("PRIV: FAILED");
        $finish;
    end
endmodule
