// branch_unit.sv — Branch / jump condition and target
// Used by the single-cycle CPU (and later by the pipeline).

module branch_unit (
    input  logic [31:0] rs1,
    input  logic [31:0] rs2,
    input  logic [2:0]  funct3,
    input  logic        branch,
    input  logic        jump,
    input  logic [31:0] pc,
    input  logic [31:0] imm,
    output logic        taken,
    output logic [31:0] target
);
    logic cond;

    always_comb begin
        case (funct3)
            3'b000: cond = (rs1 == rs2);                    // BEQ
            3'b001: cond = (rs1 != rs2);                    // BNE
            3'b100: cond = ($signed(rs1) < $signed(rs2));   // BLT
            3'b101: cond = ($signed(rs1) >= $signed(rs2));  // BGE
            3'b110: cond = (rs1 < rs2);                     // BLTU
            3'b111: cond = (rs1 >= rs2);                    // BGEU
            default: cond = 1'b0;
        endcase
    end

    assign taken  = jump || (branch && cond);
    assign target = jump ? (pc + imm) : (pc + imm);  // both use PC-relative for now
    // JALR will be handled by the CPU (rs1 + imm)
endmodule
