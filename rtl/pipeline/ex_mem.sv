// ex_mem.sv
module ex_mem (
    input  logic        clk, rst_n,
    input  logic [31:0] alu_y_in, rd2_in, pc_in,
    input  logic [4:0]  rd_in,
    input  logic        mem_read_in, mem_write_in, reg_write_in,
    input  logic [1:0]  wb_sel_in,
    input  logic [2:0]  mem_size_in,
    output logic [31:0] alu_y_out, rd2_out, pc_out,
    output logic [4:0]  rd_out,
    output logic        mem_read_out, mem_write_out, reg_write_out,
    output logic [1:0]  wb_sel_out,
    output logic [2:0]  mem_size_out
);
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            alu_y_out <= 0; rd2_out <= 0; pc_out <= 0; rd_out <= 0;
            mem_read_out <= 0; mem_write_out <= 0; reg_write_out <= 0;
            wb_sel_out <= 0; mem_size_out <= 2;
        end else begin
            alu_y_out <= alu_y_in; rd2_out <= rd2_in; pc_out <= pc_in; rd_out <= rd_in;
            mem_read_out <= mem_read_in; mem_write_out <= mem_write_in; reg_write_out <= reg_write_in;
            wb_sel_out <= wb_sel_in; mem_size_out <= mem_size_in;
        end
    end
endmodule
