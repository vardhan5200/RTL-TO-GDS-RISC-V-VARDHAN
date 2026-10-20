// alu.sv — Complete RV32I ALU (area-reduced)
//   * one 33-bit adder serves ADD, SUB, SLT and SLTU (b is inverted with a
//     carry-in of 1 for the subtracting ops; SLTU = no carry-out, SLT = sign
//     of the difference corrected for operand-sign mismatch);
//   * one right shifter serves SRL, SRA and SLL (SLL = bit-reverse, shift
//     right logical, bit-reverse).
// Results are identical to the per-op version for every op code (0-9; other
// codes give 0).
module alu (
    input  logic [31:0] a,
    input  logic [31:0] b,
    input  logic [3:0]  op,
    output logic [31:0] y,
    output logic        zero
);
    // ---- shared adder / subtractor ----
    logic        sub;
    logic [32:0] sum;
    logic        lt, ltu;
    assign sub = (op == 4'd1) || (op == 4'd8) || (op == 4'd9);
    assign sum = {1'b0, a} + {1'b0, b ^ {32{sub}}} + {32'b0, sub};
    assign ltu = !sum[32];                               // borrow out of a - b
    assign lt  = (a[31] ^ b[31]) ? a[31] : sum[31];

    // ---- shared shifter ----
    function automatic logic [31:0] rev32(input logic [31:0] v);
        for (int k = 0; k < 32; k++) rev32[k] = v[31-k];
    endfunction
    logic        sll;
    logic [31:0] sh_in, sh_out;
    logic [32:0] sh_ext;
    assign sll    = (op == 4'd5);
    assign sh_in  = sll ? rev32(a) : a;
    assign sh_ext = $signed({(op == 4'd7) && a[31], sh_in}) >>> b[4:0];
    assign sh_out = sll ? rev32(sh_ext[31:0]) : sh_ext[31:0];

    always @(*) begin
        case (op)
            4'd0, 4'd1:       y = sum[31:0];                // ADD/ADDI, SUB
            4'd2:             y = a & b;                    // AND / ANDI
            4'd3:             y = a | b;                    // OR  / ORI
            4'd4:             y = a ^ b;                    // XOR / XORI
            4'd5, 4'd6, 4'd7: y = sh_out;                   // SLL, SRL, SRA (+imm)
            4'd8:             y = {31'b0, lt};              // SLT / SLTI
            4'd9:             y = {31'b0, ltu};             // SLTU / SLTIU
            default:          y = 32'b0;
        endcase
    end
    assign zero = (y == 32'b0);
endmodule
