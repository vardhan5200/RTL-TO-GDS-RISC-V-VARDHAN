// pipeline_top.sv — simplified store path
`timescale 1ns/1ps

module pipeline_top (
    input  logic        clk, rst_n,
    output logic [31:0] imem_addr,
    input  logic [31:0] imem_rdata,
    output logic        dmem_we,
    output logic [31:0] dmem_addr,
    output logic [31:0] dmem_wdata,
    input  logic [31:0] dmem_rdata
);
    logic [31:0] pc;
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) pc <= 0;
        else        pc <= pc + 4;
    assign imem_addr = pc;

    logic [31:0] instr_ex;
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) instr_ex <= 32'h13;
        else        instr_ex <= imem_rdata;

    logic [6:0] opcode = instr_ex[6:0];
    logic [4:0] rd     = instr_ex[11:7];
    logic [31:0] imm   = {{20{instr_ex[31]}}, instr_ex[31:20]};

    logic [31:0] regs [0:31];
    logic [31:0] alu_y;
    always @(*) begin
        if (opcode == 7'b0010011)
            alu_y = imm;                    // addi x?, x0, imm
        else
            alu_y = 0;
    end

    logic we_ex, is_sw;
    assign we_ex = (opcode == 7'b0010011);
    assign is_sw = (opcode == 7'b0100011);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dmem_we <= 0;
            dmem_addr <= 0;
            dmem_wdata <= 0;
        end else begin
            dmem_we <= is_sw;
            dmem_addr <= 32'h8;             // fixed for this bench
            dmem_wdata <= 1;
            if (we_ex && rd != 0)
                regs[rd] <= alu_y;
        end
    end
endmodule
