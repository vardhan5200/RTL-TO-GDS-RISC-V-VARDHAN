// forward_unit.sv
module forward_unit (
    input  logic [4:0] rs1_ex, rs2_ex,
    input  logic [4:0] rd_mem, rd_wb,
    input  logic       reg_write_mem, reg_write_wb,
    output logic [1:0] forward_a, forward_b   // 00=reg, 01=mem, 10=wb
);
    always @(*) begin
        forward_a = 2'b00;
        forward_b = 2'b00;
        if (reg_write_mem && rd_mem != 0 && rd_mem == rs1_ex) forward_a = 2'b01;
        else if (reg_write_wb && rd_wb != 0 && rd_wb == rs1_ex) forward_a = 2'b10;
        if (reg_write_mem && rd_mem != 0 && rd_mem == rs2_ex) forward_b = 2'b01;
        else if (reg_write_wb && rd_wb != 0 && rd_wb == rs2_ex) forward_b = 2'b10;
    end
endmodule
