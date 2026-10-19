// decoder.sv — RV32I decoder (Icarus-friendly: always @(*))
module decoder (
    input  logic [31:0] instr,
    output logic        illegal,
    output logic [3:0]  alu_op,
    output logic [2:0]  imm_sel,
    output logic        alu_src_b,
    output logic        mem_read,
    output logic        mem_write,
    output logic        reg_write,
    output logic [1:0]  wb_sel,
    output logic        branch,
    output logic        jump
);
    logic [6:0] opcode;
    logic [2:0] funct3;
    logic [6:0] funct7;

    always @(*) begin
        opcode = instr[6:0];
        funct3 = instr[14:12];
        funct7 = instr[31:25];

        illegal   = 1'b0;
        alu_op    = 4'd0;
        imm_sel   = 3'd0;
        alu_src_b = 1'b0;
        mem_read  = 1'b0;
        mem_write = 1'b0;
        reg_write = 1'b0;
        wb_sel    = 2'd0;
        branch    = 1'b0;
        jump      = 1'b0;

        case (opcode)
            7'b0110011: begin // R-type
                reg_write = 1'b1;
                if (funct7 == 7'b0000000 && funct3 == 3'b000) alu_op = 4'd0;
                else if (funct7 == 7'b0100000 && funct3 == 3'b000) alu_op = 4'd1;
                else if (funct7 == 7'b0000000 && funct3 == 3'b111) alu_op = 4'd2;
                else if (funct7 == 7'b0000000 && funct3 == 3'b110) alu_op = 4'd3;
                else if (funct7 == 7'b0000000 && funct3 == 3'b100) alu_op = 4'd4;
                else if (funct7 == 7'b0000000 && funct3 == 3'b001) alu_op = 4'd5;
                else if (funct7 == 7'b0000000 && funct3 == 3'b101) alu_op = 4'd6;
                else if (funct7 == 7'b0100000 && funct3 == 3'b101) alu_op = 4'd7;
                else if (funct7 == 7'b0000000 && funct3 == 3'b010) alu_op = 4'd8;
                else if (funct7 == 7'b0000000 && funct3 == 3'b011) alu_op = 4'd9;
                else illegal = 1'b1;
            end
            7'b0010011: begin // I-type ALU
                reg_write = 1'b1;
                alu_src_b = 1'b1;
                imm_sel   = 3'd0;
                if (funct3 == 3'b000) alu_op = 4'd0;
                else if (funct3 == 3'b111) alu_op = 4'd2;
                else if (funct3 == 3'b110) alu_op = 4'd3;
                else if (funct3 == 3'b100) alu_op = 4'd4;
                else if (funct3 == 3'b010) alu_op = 4'd8;
                else if (funct3 == 3'b011) alu_op = 4'd9;
                else if (funct3 == 3'b001) begin
                    alu_op = 4'd5;
                    if (funct7 != 7'b0000000) illegal = 1'b1;
                end
                else if (funct3 == 3'b101) begin
                    if (funct7 == 7'b0000000) alu_op = 4'd6;
                    else if (funct7 == 7'b0100000) alu_op = 4'd7;
                    else illegal = 1'b1;
                end
                else illegal = 1'b1;
            end
            7'b0000011: begin // Loads
                reg_write = 1'b1;
                mem_read  = 1'b1;
                alu_src_b = 1'b1;
                imm_sel   = 3'd0;
                wb_sel    = 2'd1;
            end
            7'b0100011: begin // Stores
                mem_write = 1'b1;
                alu_src_b = 1'b1;
                imm_sel   = 3'd1;
            end
            7'b1100011: begin // Branches
                branch  = 1'b1;
                imm_sel = 3'd2;
                alu_op  = 4'd1;
            end
            7'b1101111: begin // JAL
                jump      = 1'b1;
                reg_write = 1'b1;
                imm_sel   = 3'd4;
                wb_sel    = 2'd2;
            end
            7'b1100111: begin // JALR
                if (funct3 == 3'b000) begin
                    jump      = 1'b1;
                    reg_write = 1'b1;
                    alu_src_b = 1'b1;
                    imm_sel   = 3'd0;
                    wb_sel    = 2'd2;
                end else illegal = 1'b1;
            end
            7'b0110111: begin // LUI
                reg_write = 1'b1;
                imm_sel   = 3'd3;
                alu_src_b = 1'b1;
            end
            7'b0010111: begin // AUIPC
                reg_write = 1'b1;
                imm_sel   = 3'd3;
                alu_src_b = 1'b1;
            end
            default: illegal = 1'b1;
        endcase
    end
endmodule
