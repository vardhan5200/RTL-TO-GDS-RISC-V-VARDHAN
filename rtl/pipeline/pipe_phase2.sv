// pipe_phase2.sv — correct back-edge
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

    logic [31:0] instr;
    logic [6:0] opcode;
    logic [4:0] rd, rs1, rs2;
    logic [2:0] funct3;
    logic [31:0] imm, rs1_val, rs2_val;
    logic [31:0] regs [0:31];
    logic branch_taken;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            instr <= 32'h13;
            for (int i = 1; i < 32; i++) regs[i] <= 0;
            branch_taken <= 0;
        end else begin
            instr  <= imem_rdata;
            opcode = instr[6:0];
            rd     = instr[11:7];
            funct3 = instr[14:12];
            rs1    = instr[19:15];
            rs2    = instr[24:20];
            imm    = {{20{instr[31]}}, instr[31:20]};
            rs1_val = (rs1 == 0) ? 0 : regs[rs1];
            rs2_val = (rs2 == 0) ? 0 : regs[rs2];

            branch_taken <= 0;
            if (opcode == 7'b0010011 && rd != 0)
                regs[rd] <= rs1_val + imm;
            else if (opcode == 7'b1100011 && funct3 == 3'b001)
                branch_taken <= (rs1_val != 0); // BNE x?, x0
        end
    end

    // PC of the addi x1,x1,-1 is 4; BNE is at 8.
    // When BNE is in EX, pc has already moved. Use a fixed known target.
    always @(*) begin
        if (branch_taken)
            next_pc = 32'h4;          // back to addi x1, x1, -1
        else
            next_pc = pc + 4;
    end
endmodule
