// mem_wb.sv
module mem_wb (
    input  logic        clk, rst_n,
    input  logic [31:0] alu_y_in, load_data_in, pc_in,
    input  logic [4:0]  rd_in,
    input  logic        reg_write_in,
    input  logic [1:0]  wb_sel_in,
    output logic [31:0] alu_y_out, load_data_out, pc_out,
    output logic [4:0]  rd_out,
    output logic        reg_write_out,
    output logic [1:0]  wb_sel_out
);
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            alu_y_out <= 0; load_data_out <= 0; pc_out <= 0; rd_out <= 0;
            reg_write_out <= 0; wb_sel_out <= 0;
        end else begin
            alu_y_out <= alu_y_in; load_data_out <= load_data_in; pc_out <= pc_in; rd_out <= rd_in;
            reg_write_out <= reg_write_in; wb_sel_out <= wb_sel_in;
        end
    end
endmodule
