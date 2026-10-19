// if_id.sv
module if_id (
    input  logic        clk, rst_n, stall, flush,
    input  logic [31:0] pc_in, instr_in,
    output logic [31:0] pc_out, instr_out
);
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n || flush) begin
            pc_out    <= 0;
            instr_out <= 32'h00000013; // nop
        end else if (!stall) begin
            pc_out    <= pc_in;
            instr_out <= instr_in;
        end
    end
endmodule
