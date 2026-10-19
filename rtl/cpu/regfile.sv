// regfile.sv — with debug
module regfile (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        we,
    input  logic [4:0]  rs1,
    input  logic [4:0]  rs2,
    input  logic [4:0]  rd,
    input  logic [31:0] wd,
    output logic [31:0] rd1,
    output logic [31:0] rd2
);
    logic [31:0] regs [1:31];
    integer i;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 1; i < 32; i = i + 1)
                regs[i] <= 32'b0;
        end else if (we && (rd != 5'd0)) begin
            regs[rd] <= wd;
            $display("REG WRITE: x%0d <= %0d (we=%b)", rd, wd, we);
        end
    end

    always_comb begin
        rd1 = (rs1 == 5'd0) ? 32'b0 : regs[rs1];
        rd2 = (rs2 == 5'd0) ? 32'b0 : regs[rs2];
    end
endmodule
