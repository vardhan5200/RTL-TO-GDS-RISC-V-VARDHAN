// hazard_unit.sv
module hazard_unit (
    input  logic [4:0] rs1_id, rs2_id, rd_ex,
    input  logic       mem_read_ex,
    output logic       stall, flush_id
);
    // Load-use hazard: stall one cycle
    assign stall    = mem_read_ex && (rd_ex != 0) && (rd_ex == rs1_id || rd_ex == rs2_id);
    assign flush_id = 1'b0; // control flush handled in CPU for now
endmodule
