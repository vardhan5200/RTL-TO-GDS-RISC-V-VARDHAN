// simple_memory.sv — Behavioral memory for simulation
// Word-addressable, 64 KiB, zero-cycle read for the reference CPU.

module simple_memory (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        we,
    input  logic [31:0] addr,
    input  logic [31:0] wdata,
    input  logic [3:0]  wstrb,
    output logic [31:0] rdata
);
    logic [31:0] mem [0:16383];  // 64 KiB
    integer i;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < 16384; i = i + 1)
                mem[i] <= 32'b0;
        end else if (we) begin
            if (wstrb[0]) mem[addr[15:2]][7:0]   <= wdata[7:0];
            if (wstrb[1]) mem[addr[15:2]][15:8]  <= wdata[15:8];
            if (wstrb[2]) mem[addr[15:2]][23:16] <= wdata[23:16];
            if (wstrb[3]) mem[addr[15:2]][31:24] <= wdata[31:24];
        end
    end

    assign rdata = mem[addr[15:2]];
endmodule
