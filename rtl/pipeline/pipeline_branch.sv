// pipeline_branch.sv — with branch debug
`timescale 1ns/1ps

module pipeline_branch (
    input  logic        clk, rst_n,
    output logic [31:0] imem_addr,
    input  logic [31:0] imem_rdata,
    output logic        dmem_we,
    output logic [31:0] dmem_addr,
    output logic [31:0] dmem_wdata,
    input  logic [31:0] dmem_rdata
);
    logic [31:0] pc, next_pc;
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) pc <= 0;
        else        pc <= next_pc;
    assign imem_addr = pc;

    logic [31:0] instr_id, pc_id;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) instr_id <= 32'h13;
        else        instr_id <= imem_rdata;
        pc_id <= pc;
    end

    logic [6:0] opcode = instr_id[6:0];
    logic [4:0] rd_id = instr_id[11:7];
    logic [4:0] rs1_id = instr_id[19:15];
    logic [4:0] rs2_id = instr_id[24:20];
    logic [2:0] funct3 = instr_id[14:12];
    logic [31:0] imm_id = {{20{instr_id[31]}}, instr_id[31:20]};
    logic [31:0] imm_b  = {{19{instr_id[31]}}, instr_id[31], instr_id[7],
                           instr_id[30:25], instr_id[11:8], 1'b0};

    logic [31:0] regs [0:31];
    logic [31:0] rd1 = (rs1_id==0) ? 0 : regs[rs1_id];
    logic [31:0] rd2 = (rs2_id==0) ? 0 : regs[rs2_id];

    logic [31:0] rd1_ex, rd2_ex, imm_ex, pc_ex;
    logic [4:0] rd_ex;
    logic [6:0] opcode_ex;
    logic [2:0] funct3_ex;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd1_ex<=0; rd2_ex<=0; imm_ex<=0; pc_ex<=0;
            rd_ex<=0; opcode_ex<=0; funct3_ex<=0;
        end else begin
            rd1_ex <= rd1; rd2_ex <= rd2;
            imm_ex <= (opcode==7'b1100011) ? imm_b : imm_id;
            pc_ex <= pc_id;
            rd_ex <= rd_id; opcode_ex <= opcode; funct3_ex <= funct3;
        end
    end

    logic [31:0] alu_y;
    logic branch_taken;
    always @(*) begin
        alu_y = rd1_ex + imm_ex;
        branch_taken = 0;
        if (opcode_ex == 7'b1100011 && funct3_ex == 3'b001)
            branch_taken = (rd1_ex != rd2_ex);
    end

    always @(*) begin
        if (branch_taken)
            next_pc = pc_ex + imm_ex;
        else
            next_pc = pc + 4;
    end

    always_ff @(posedge clk) begin
        if (opcode_ex == 7'b1100011)
            $display("BNE pc_ex=%h imm=%h taken=%b rd1=%0d next=%h",
                     pc_ex, imm_ex, branch_taken, rd1_ex, next_pc);
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i=1;i<32;i++) regs[i]<=0;
        end else if (opcode_ex == 7'b0010011 && rd_ex != 0)
            regs[rd_ex] <= alu_y;
    end

    assign dmem_we = 0;
    assign dmem_addr = 0;
    assign dmem_wdata = 0;
endmodule
