// pipe_phase2.sv — 2-stage (IF / EX) ADDI + BNE experiment.
// Fixed: branch is resolved combinationally in EX from the branch's own PC
// (pc_ex + B-imm, no hard-coded target), redirects next_pc in the same cycle,
// and squashes the wrong-path instruction fetched behind it (1-cycle penalty).
`timescale 1ns/1ps

module pipe_phase2 (
    input  logic clk, rst_n,
    output logic [31:0] imem_addr,
    input  logic [31:0] imem_rdata
);
    logic [31:0] pc, next_pc;
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) pc <= 0;
        else        pc <= next_pc;
    assign imem_addr = pc;

    logic [31:0] instr, pc_ex;
    logic [6:0]  opcode;
    logic [4:0]  rd, rs1, rs2;
    logic [2:0]  funct3;
    logic [31:0] imm, imm_b, rs1_val, rs2_val;
    logic [31:0] regs [0:31];
    logic        branch_taken;

    always @(*) begin
        opcode  = instr[6:0];
        rd      = instr[11:7];
        funct3  = instr[14:12];
        rs1     = instr[19:15];
        rs2     = instr[24:20];
        imm     = {{20{instr[31]}}, instr[31:20]};
        imm_b   = {{19{instr[31]}}, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0};
        rs1_val = (rs1 == 0) ? 0 : regs[rs1];
        rs2_val = (rs2 == 0) ? 0 : regs[rs2];
        branch_taken = (opcode == 7'b1100011) && (funct3 == 3'b001) && (rs1_val != rs2_val);
        next_pc = branch_taken ? (pc_ex + imm_b) : (pc + 4);
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            instr <= 32'h13; pc_ex <= 0;
            for (int i = 0; i < 32; i++) regs[i] <= 0;
        end else begin
            instr <= branch_taken ? 32'h13 : imem_rdata;   // squash wrong path
            pc_ex <= pc;
            if (opcode == 7'b0010011 && rd != 0)
                regs[rd] <= rs1_val + imm;
        end
    end
endmodule
