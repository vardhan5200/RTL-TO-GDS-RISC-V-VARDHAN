// div_unit.sv — RISC-V DIV/DIVU/REM/REMU around the unsigned divider (div.sv).
//   op = funct3[1:0]: 00 DIV, 01 DIVU, 10 REM, 11 REMU.
//   Same start/done handshake as div.sv / mul.sv; result is registered and
//   held until the next start. Signed ops divide magnitudes and fix the signs:
//   quotient negative iff signs differ, remainder takes the dividend's sign.
//   Spec corner cases: x/0 -> quotient all ones, remainder = dividend;
//   INT_MIN / -1 -> quotient INT_MIN, remainder 0 (both fall out naturally).
module div_unit (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        start,
    input  logic [1:0]  op,
    input  logic [31:0] a,       // rs1 (dividend)
    input  logic [31:0] b,       // rs2 (divisor)
    output logic [31:0] result,
    output logic        done
);
    logic        is_signed;
    logic [31:0] ua, ub, q, r;
    assign is_signed = !op[0];
    assign ua = (is_signed && a[31]) ? -a : a;
    assign ub = (is_signed && b[31]) ? -b : b;

    logic       neg_q, neg_r, want_rem, busy;
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) begin neg_q <= 0; neg_r <= 0; want_rem <= 0; busy <= 0; end
        else if (start && !busy) begin
            neg_q    <= is_signed && (a[31] ^ b[31]) && (b != 0);  // x/0 stays all ones
            neg_r    <= is_signed && a[31];
            want_rem <= op[1];
            busy     <= 1;
        end else if (done) busy <= 0;

    div u_div (.clk, .rst_n, .start(start && !busy), .dividend(ua), .divisor(ub),
               .quotient(q), .remainder(r), .done);

    // one output negator: select quotient/remainder first, then fix the sign
    logic [31:0] sel;
    logic        neg;
    assign sel    = want_rem ? r : q;
    assign neg    = want_rem ? neg_r : neg_q;
    assign result = neg ? -sel : sel;
endmodule
