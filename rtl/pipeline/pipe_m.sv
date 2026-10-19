// pipe_m.sv — busy declared first
`timescale 1ns/1ps

module pipe_m (
    input  logic clk, rst_n,
    output logic [31:0] imem_addr,
    input  logic [31:0] imem_rdata
);
    logic busy;   // declared early
    logic [31:0] pc;
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) pc <= 0;
        else if (!busy) pc <= pc + 4;
    assign imem_addr = pc;

    logic [31:0] instr;
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) instr <= 32'h13;
        else if (!busy) instr <= imem_rdata;

    logic [6:0] opcode;
    logic [4:0] rd, rs1, rs2;
    logic [2:0] funct3;
    logic [6:0] funct7;
    logic [31:0] imm;

    always @(*) begin
        opcode = instr[6:0];
        rd     = instr[11:7];
        funct3 = instr[14:12];
        rs1    = instr[19:15];
        rs2    = instr[24:20];
        funct7 = instr[31:25];
        imm    = {{20{instr[31]}}, instr[31:20]};
    end

    logic [31:0] regs [0:31];
    logic [31:0] rs1_val = (rs1==0) ? 0 : regs[rs1];
    logic [31:0] rs2_val = (rs2==0) ? 0 : regs[rs2];

    logic mul_start, mul_done;
    logic [31:0] mul_result;

    mul u_mul (
        .clk, .rst_n,
        .start(mul_start),
        .a(rs1_val), .b(rs2_val),
        .result(mul_result), .done(mul_done)
    );

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy <= 0;
            mul_start <= 0;
            for (int i=1;i<32;i++) regs[i]<=0;
        end else begin
            mul_start <= 0;
            if (!busy && opcode==7'b0110011 && funct3==0 && funct7==7'h01) begin
                mul_start <= 1;
                busy <= 1;
            end else if (!busy && opcode==7'b0010011 && rd!=0) begin
                regs[rd] <= rs1_val + imm;
            end else if (busy && mul_done) begin
                regs[rd] <= mul_result;
                busy <= 0;
            end
        end
    end
endmodule
