// pc.sv — Program counter
// Synchronous reset to 0x0000_0000.

module pc (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        stall,
    input  logic [31:0] next_pc,
    output logic [31:0] pc_out
);
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            pc_out <= 32'h0000_0000;
        else if (!stall)
            pc_out <= next_pc;
    end
endmodule
