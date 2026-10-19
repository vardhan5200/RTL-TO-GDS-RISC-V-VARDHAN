// pipe_m.sv — single-issue ADDI + MUL experiment using rtl/cpu/mul.sv.
// Fixed: (1) rs1_val/rs2_val were one-time declaration initializers, not
// continuous assigns; (2) the stall was registered, so the instruction behind
// MUL overwrote `instr` on the same edge that set `busy` and the MUL lost its
// operands/rd. The hold is now combinational from the decoded MUL.
`timescale 1ns/1ps

module pipe_m (
    input  logic clk, rst_n,
    output logic [31:0] imem_addr,
    input  logic [31:0] imem_rdata
);
    logic busy;   // multiplier started, waiting for done
    logic hold;   // freeze fetch/decode while MUL is outstanding
    logic [31:0] pc;
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n)     pc <= 0;
        else if (!hold) pc <= pc + 4;
    assign imem_addr = pc;

    logic [31:0] instr;
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n)     instr <= 32'h13;
        else if (!hold) instr <= imem_rdata;

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
    logic [31:0] rs1_val, rs2_val;
    assign rs1_val = (rs1==0) ? 0 : regs[rs1];
    assign rs2_val = (rs2==0) ? 0 : regs[rs2];

    logic is_mul, mul_start, mul_done;
    logic [31:0] mul_result;
    assign is_mul    = (opcode==7'b0110011) && (funct3==0) && (funct7==7'h01);
    assign mul_start = is_mul && !busy;
    assign hold      = is_mul && !mul_done;

    mul u_mul (
        .clk, .rst_n,
        .start(mul_start),
        .a(rs1_val), .b(rs2_val),
        .result(mul_result), .done(mul_done)
    );

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy <= 0;
            for (int i=0;i<32;i++) regs[i]<=0;
        end else begin
            if (mul_start)     busy <= 1;
            else if (mul_done) busy <= 0;
            if (is_mul && mul_done && rd!=0)
                regs[rd] <= mul_result;
            else if (opcode==7'b0010011 && rd!=0)
                regs[rd] <= rs1_val + imm;
        end
    end
endmodule
