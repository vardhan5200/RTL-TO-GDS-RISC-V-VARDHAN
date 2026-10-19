// id_ex.sv
module id_ex (
    input  logic        clk, rst_n, flush,
    input  logic [31:0] pc_in, rd1_in, rd2_in, imm_in,
    input  logic [4:0]  rs1_in, rs2_in, rd_in,
    input  logic [3:0]  alu_op_in,
    input  logic        alu_src_b_in, mem_read_in, mem_write_in, reg_write_in, branch_in, jump_in, jalr_in,
    input  logic [1:0]  wb_sel_in,
    input  logic [2:0]  mem_size_in,
    input  logic        mem_unsigned_in,
    output logic [31:0] pc_out, rd1_out, rd2_out, imm_out,
    output logic [4:0]  rs1_out, rs2_out, rd_out,
    output logic [3:0]  alu_op_out,
    output logic        alu_src_b_out, mem_read_out, mem_write_out, reg_write_out, branch_out, jump_out, jalr_out,
    output logic [1:0]  wb_sel_out,
    output logic [2:0]  mem_size_out,
    output logic        mem_unsigned_out
);
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n || flush) begin
            pc_out <= 0; rd1_out <= 0; rd2_out <= 0; imm_out <= 0;
            rs1_out <= 0; rs2_out <= 0; rd_out <= 0;
            alu_op_out <= 0; alu_src_b_out <= 0;
            mem_read_out <= 0; mem_write_out <= 0; reg_write_out <= 0;
            branch_out <= 0; jump_out <= 0; jalr_out <= 0;
            wb_sel_out <= 0; mem_size_out <= 2; mem_unsigned_out <= 0;
        end else begin
            pc_out <= pc_in; rd1_out <= rd1_in; rd2_out <= rd2_in; imm_out <= imm_in;
            rs1_out <= rs1_in; rs2_out <= rs2_in; rd_out <= rd_in;
            alu_op_out <= alu_op_in; alu_src_b_out <= alu_src_b_in;
            mem_read_out <= mem_read_in; mem_write_out <= mem_write_in; reg_write_out <= reg_write_in;
            branch_out <= branch_in; jump_out <= jump_in; jalr_out <= jalr_in;
            wb_sel_out <= wb_sel_in; mem_size_out <= mem_size_in; mem_unsigned_out <= mem_unsigned_in;
        end
    end
endmodule
