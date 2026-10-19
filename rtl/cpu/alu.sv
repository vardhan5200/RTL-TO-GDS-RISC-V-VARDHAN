// alu.sv — Complete RV32I ALU
module alu (
    input  logic [31:0] a,
    input  logic [31:0] b,
    input  logic [3:0]  op,
    output logic [31:0] y,
    output logic        zero
);
    always @(*) begin
        case (op)
            4'd0:  y = a + b;                              // ADD / ADDI
            4'd1:  y = a - b;                              // SUB
            4'd2:  y = a & b;                              // AND / ANDI
            4'd3:  y = a | b;                              // OR  / ORI
            4'd4:  y = a ^ b;                              // XOR / XORI
            4'd5:  y = a << b[4:0];                        // SLL / SLLI
            4'd6:  y = a >> b[4:0];                        // SRL / SRLI
            4'd7:  y = $signed(a) >>> b[4:0];              // SRA / SRAI
            4'd8:  y = {31'b0, ($signed(a) < $signed(b))}; // SLT / SLTI
            4'd9:  y = {31'b0, (a < b)};                   // SLTU / SLTIU
            default: y = 32'b0;
        endcase
    end
    assign zero = (y == 32'b0);
endmodule
