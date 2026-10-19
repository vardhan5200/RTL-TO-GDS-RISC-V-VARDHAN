// alu.sv — RV32I ALU
// Operations match the decoder's alu_op encoding.

module alu (
    input  logic [31:0] a,
    input  logic [31:0] b,
    input  logic [3:0]  op,
    output logic [31:0] y,
    output logic        zero
);
    localparam ADD  = 4'd0;
    localparam SUB  = 4'd1;
    localparam AND_OP = 4'd2;
    localparam OR_OP  = 4'd3;
    localparam XOR_OP = 4'd4;
    localparam SLL  = 4'd5;
    localparam SRL  = 4'd6;
    localparam SRA  = 4'd7;
    localparam SLT  = 4'd8;
    localparam SLTU = 4'd9;

    always_comb begin
        y = 32'b0;
        case (op)
            ADD:     y = a + b;
            SUB:     y = a - b;
            AND_OP:  y = a & b;
            OR_OP:   y = a | b;
            XOR_OP:  y = a ^ b;
            SLL:     y = a << b[4:0];
            SRL:     y = a >> b[4:0];
            SRA:     y = $signed(a) >>> b[4:0];
            SLT:     y = {31'b0, ($signed(a) < $signed(b))};
            SLTU:    y = {31'b0, (a < b)};
            default: y = 32'b0;
        endcase
    end

    assign zero = (y == 32'b0);
endmodule
