// decoder.sv — Complete RV32I decoder
module decoder (
    input  logic [31:0] instr,
    output logic        illegal,
    output logic [3:0]  alu_op,
    output logic [2:0]  imm_sel,
    output logic        alu_src_b,
    output logic        mem_read,
    output logic        mem_write,
    output logic [2:0]  mem_size,
    output logic        mem_unsigned,
    output logic        reg_write,
    output logic [1:0]  wb_sel,
    output logic        branch,
    output logic        jump,
    output logic        jalr
);
    logic [6:0] opcode;
    logic [2:0] funct3;
    logic [6:0] funct7;

    always @(*) begin
        opcode = instr[6:0];
        funct3 = instr[14:12];
        funct7 = instr[31:25];

        illegal = 0; alu_op = 0; imm_sel = 0; alu_src_b = 0;
        mem_read = 0; mem_write = 0; mem_size = 2; mem_unsigned = 0;
        reg_write = 0; wb_sel = 0; branch = 0; jump = 0; jalr = 0;

        case (opcode)
            7'b0110011: begin // R-type
                reg_write = 1;
                if      (funct7==0 && funct3==0) alu_op = 0;
                else if (funct7==7'h20 && funct3==0) alu_op = 1;
                else if (funct7==0 && funct3==7) alu_op = 2;
                else if (funct7==0 && funct3==6) alu_op = 3;
                else if (funct7==0 && funct3==4) alu_op = 4;
                else if (funct7==0 && funct3==1) alu_op = 5;
                else if (funct7==0 && funct3==5) alu_op = 6;
                else if (funct7==7'h20 && funct3==5) alu_op = 7;
                else if (funct7==0 && funct3==2) alu_op = 8;
                else if (funct7==0 && funct3==3) alu_op = 9;
                else illegal = 1;
            end
            7'b0010011: begin // I-ALU
                reg_write = 1; alu_src_b = 1; imm_sel = 0;
                if      (funct3==0) alu_op = 0;
                else if (funct3==7) alu_op = 2;
                else if (funct3==6) alu_op = 3;
                else if (funct3==4) alu_op = 4;
                else if (funct3==2) alu_op = 8;
                else if (funct3==3) alu_op = 9;
                else if (funct3==1) begin alu_op = 5; if (funct7!=0) illegal=1; end
                else if (funct3==5) begin
                    if (funct7==0) alu_op = 6;
                    else if (funct7==7'h20) alu_op = 7;
                    else illegal = 1;
                end else illegal = 1;
            end
            7'b0000011: begin // Loads
                reg_write = 1; mem_read = 1; alu_src_b = 1; imm_sel = 0; wb_sel = 1;
                case (funct3)
                    0: begin mem_size=0; mem_unsigned=0; end
                    1: begin mem_size=1; mem_unsigned=0; end
                    2: begin mem_size=2; mem_unsigned=0; end
                    4: begin mem_size=0; mem_unsigned=1; end
                    5: begin mem_size=1; mem_unsigned=1; end
                    default: illegal = 1;
                endcase
            end
            7'b0100011: begin // Stores
                mem_write = 1; alu_src_b = 1; imm_sel = 1;
                case (funct3)
                    0: mem_size = 0;
                    1: mem_size = 1;
                    2: mem_size = 2;
                    default: illegal = 1;
                endcase
            end
            7'b1100011: begin branch = 1; imm_sel = 2; alu_op = 1; end // Branches
            7'b1101111: begin jump = 1; reg_write = 1; imm_sel = 4; wb_sel = 2; end // JAL
            7'b1100111: begin // JALR
                if (funct3==0) begin
                    jump = 1; jalr = 1; reg_write = 1; alu_src_b = 1; imm_sel = 0; wb_sel = 2;
                end else illegal = 1;
            end
            7'b0110111: begin reg_write = 1; imm_sel = 3; alu_src_b = 1; end // LUI
            7'b0010111: begin reg_write = 1; imm_sel = 3; alu_src_b = 1; end // AUIPC
            7'b1110011: begin /* ECALL/EBREAK */ end
            7'b0001111: begin /* FENCE */ end
            default: illegal = 1;
        endcase
    end
endmodule
