// priv_unit.sv — standalone machine-mode trap/CSR unit.
`timescale 1ns/1ps
//
// Sits beside a pipeline at the commit point: present one instruction per
// cycle (instr_valid, instr, pc, rs1_data). The unit
//   * executes CSRRW/CSRRS/CSRRC/CSRRWI/CSRRSI/CSRRCI (rd_we/rd_wdata = old CSR)
//   * raises synchronous exceptions:
//       illegal instruction (cause 2, mtval = instr)  — via rtl/cpu/decoder
//         plus SYSTEM-opcode decode / CSR legality
//       breakpoint EBREAK   (cause 3, mtval = pc)
//       ecall from M-mode   (cause 11, mtval = 0)
//       external synchronous exception (xcpt_valid/xcpt_cause/xcpt_tval),
//         e.g. an MMU page fault (12/13/15) or access fault (1/5/7) that the
//         pipeline detects after the instruction was presented (multi-cycle
//         translation). It may be raised on a later cycle with instr_valid=0;
//         pc must still be the faulting instruction's pc (-> mepc). It has
//         the highest priority (the faulting instruction is the oldest one).
//   * takes interrupts at an instruction boundary (before instr executes),
//     when mstatus.MIE && (mie & mip) != 0. Priority MEI(11) > MSI(3) > MTI(7).
//     mepc = pc of the not-yet-executed instruction, mcause = {1, code}.
//   * MRET: redirect to mepc, MIE <= MPIE, MPIE <= 1.
// redirect/redirect_pc tell the pipeline to flush younger instructions and
// refetch from redirect_pc (mtvec base, or base + 4*code in vectored mode).
// It is not yet wired into pipeline_cpu.sv (integration is a follow-up).
module priv_unit #(
    parameter logic [31:0] HART_ID = 32'd0
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        instr_valid,
    input  logic [31:0] instr,
    input  logic [31:0] pc,
    input  logic [31:0] rs1_data,
    input  logic        mtip, msip, meip,
    input  logic        xcpt_valid = 1'b0,   // external synchronous exception
    input  logic [31:0] xcpt_cause = 32'b0,
    input  logic [31:0] xcpt_tval  = 32'b0,
    output logic        rd_we,          // CSR instr writes rd (rd != x0)
    output logic [31:0] rd_wdata,
    output logic        redirect,       // flush + jump to redirect_pc
    output logic [31:0] redirect_pc,
    output logic        trap,           // exception or interrupt taken
    output logic        irq_taken,
    output logic        mret,
    output logic [31:0] cause_o
);
    // ---- base-ISA legality from the existing decoder (unmodified) ----
    logic dec_illegal;
    logic [3:0] u_alu; logic [2:0] u_is, u_ms; logic u_b, u_mr, u_mw, u_mu, u_rw, u_br, u_j, u_jr;
    logic [1:0] u_wb;
    decoder u_dec (.instr, .illegal(dec_illegal), .alu_op(u_alu), .imm_sel(u_is),
                   .alu_src_b(u_b), .mem_read(u_mr), .mem_write(u_mw), .mem_size(u_ms),
                   .mem_unsigned(u_mu), .reg_write(u_rw), .wb_sel(u_wb),
                   .branch(u_br), .jump(u_j), .jalr(u_jr));

    wire [6:0]  opcode = instr[6:0];
    wire [4:0]  rd     = instr[11:7];
    wire [2:0]  funct3 = instr[14:12];
    wire [4:0]  rs1    = instr[19:15];
    wire [11:0] csr_a  = instr[31:20];
    wire is_system = (opcode == 7'b1110011);
    wire is_csr    = is_system && (funct3 != 3'b000) && (funct3 != 3'b100);
    wire is_priv0  = is_system && (funct3 == 3'b000) && (rd == 5'd0) && (rs1 == 5'd0);
    wire is_ecall  = is_priv0 && (instr[31:20] == 12'h000);
    wire is_ebreak = is_priv0 && (instr[31:20] == 12'h001);
    wire is_mret   = is_priv0 && (instr[31:20] == 12'h302);
    wire is_wfi    = is_priv0 && (instr[31:20] == 12'h105); // treated as NOP

    // ---- CSR file ----
    logic [31:0] csr_rdata, mtvec, mepc, mie_v, mip_v;
    logic csr_illegal, gie;
    logic trap_take; logic [31:0] trap_cause, trap_tval;

    csr_file #(.HART_ID(HART_ID)) u_csr (
        .clk, .rst_n,
        .csr_valid(instr_valid && is_csr), .csr_commit(!trap_take),
        .csr_op(funct3), .csr_addr(csr_a),
        .csr_src(funct3[2] ? {27'b0, rs1} : rs1_data), .csr_src_zero(rs1 == 5'd0),
        .csr_rdata, .csr_illegal,
        .trap_take, .trap_cause, .trap_epc(pc), .trap_tval,
        .mret_take(mret), .instret_inc(instr_valid && !trap_take),
        .mtip, .msip, .meip,
        .mtvec_o(mtvec), .mepc_o(mepc), .mstatus_mie_o(gie), .mie_o(mie_v), .mip_o(mip_v));

    // ---- interrupt selection ----
    wire [31:0] pend = mie_v & mip_v;
    logic irq_pend; logic [4:0] irq_code;
    always @(*) begin
        irq_pend = gie && (pend[11] || pend[3] || pend[7]);
        if      (pend[11]) irq_code = 5'd11;
        else if (pend[3])  irq_code = 5'd3;
        else               irq_code = 5'd7;
    end

    // ---- exception selection ----
    wire illegal = (is_system ? !(is_csr || is_ecall || is_ebreak || is_mret || is_wfi)
                              : dec_illegal) || (is_csr && csr_illegal);

    always @(*) begin
        irq_taken  = instr_valid && irq_pend && !xcpt_valid;
        trap_take  = 1'b0; trap_cause = 32'b0; trap_tval = 32'b0;
        if (xcpt_valid) begin
            trap_take = 1'b1; trap_cause = xcpt_cause; trap_tval = xcpt_tval;
        end else if (irq_taken) begin
            trap_take = 1'b1; trap_cause = {1'b1, 26'b0, irq_code};
        end else if (instr_valid && illegal) begin
            trap_take = 1'b1; trap_cause = 32'd2;  trap_tval = instr;
        end else if (instr_valid && is_ebreak) begin
            trap_take = 1'b1; trap_cause = 32'd3;  trap_tval = pc;
        end else if (instr_valid && is_ecall) begin
            trap_take = 1'b1; trap_cause = 32'd11;
        end
        trap    = trap_take;
        cause_o = trap_cause;
        mret    = instr_valid && is_mret && !trap_take;

        redirect = trap_take || mret;
        if (mret)
            redirect_pc = mepc;
        else if (irq_taken && mtvec[0])
            redirect_pc = {mtvec[31:2], 2'b00} + {25'b0, irq_code, 2'b00};
        else
            redirect_pc = {mtvec[31:2], 2'b00};

        rd_we    = instr_valid && is_csr && !trap_take && (rd != 5'd0);
        rd_wdata = csr_rdata;
    end
endmodule
