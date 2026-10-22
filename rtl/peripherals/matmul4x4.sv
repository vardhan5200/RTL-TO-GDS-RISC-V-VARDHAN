// matmul4x4.sv — memory-mapped 4x4 signed matrix multiply accelerator.
//   C = A x B, A/B elements 16-bit signed (low half of each word, sign-
//   extended on read-back), C elements 32-bit (two's complement, wraps on
//   overflow: |sum| can reach 2^32 only for all-(-32768) inputs).
// One multiply-accumulate per cycle: 64 MAC cycles + 1 => DONE.
// Register block (byte offsets within a 256-byte window, word accesses):
//   0x00-0x3C  A[0..15]  RW  row-major, A[r][c] at 0x00 + 4*(4r+c)
//   0x40-0x7C  B[0..15]  RW  row-major
//   0x80-0xBC  C[0..15]  RO  row-major, valid when STATUS.DONE
//   0xC0       CTRL      W   bit0 START (ignored while BUSY); reads 0
//   0xC4       STATUS    R   bit0 BUSY, bit1 DONE (cleared by START)
//   0xC8       CYCLES    R   clock cycles taken by the last run (65)
// Writes to A/B while BUSY are ignored.
module matmul4x4 (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        sel,
    input  logic        we,
    input  logic [7:0]  addr,
    input  logic [31:0] wdata,
    output logic [31:0] rdata,
    output logic        done_o
);
    localparam logic [7:0] CTRL = 8'hC0, STATUS = 8'hC4, CYCLES = 8'hC8;

    logic signed [15:0] a [0:15];
    logic signed [15:0] b [0:15];
    logic signed [31:0] c [0:15];
    logic        busy, done;
    logic [1:0]  i, j, k;
    logic signed [31:0] acc;
    logic [7:0]  cyc;

    wire wr = sel && we;
    wire signed [31:0] prod = a[{i, k}] * b[{k, j}];   // 16x16 -> 32 signed
    wire signed [31:0] acc_next = acc + prod;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int n = 0; n < 16; n++) begin a[n] <= '0; b[n] <= '0; c[n] <= '0; end
            busy <= 1'b0; done <= 1'b0; i <= 0; j <= 0; k <= 0; acc <= '0; cyc <= '0;
        end else begin
            if (wr && !busy && addr[7:6] == 2'b00) a[addr[5:2]] <= wdata[15:0];
            if (wr && !busy && addr[7:6] == 2'b01) b[addr[5:2]] <= wdata[15:0];
            if (wr && !busy && addr == CTRL && wdata[0]) begin
                busy <= 1'b1; done <= 1'b0;
                i <= 0; j <= 0; k <= 0; acc <= '0; cyc <= 8'd1;
            end else if (busy) begin
                cyc <= cyc + 1'b1;
                if (k == 2'd3) begin
                    c[{i, j}] <= acc_next;
                    acc <= '0;
                    k   <= 0;
                    if (j == 2'd3) begin
                        j <= 0;
                        if (i == 2'd3) begin busy <= 1'b0; done <= 1'b1; end
                        else i <= i + 1'b1;
                    end else
                        j <= j + 1'b1;
                end else begin
                    acc <= acc_next;
                    k   <= k + 1'b1;
                end
            end
        end
    end

    assign done_o = done;

    always @(*) begin
        case (addr[7:6])
            2'b00:   rdata = 32'(a[addr[5:2]]);          // sign-extended
            2'b01:   rdata = 32'(b[addr[5:2]]);
            2'b10:   rdata = c[addr[5:2]];
            default: case (addr)
                         STATUS:  rdata = {30'd0, done, busy};
                         CYCLES:  rdata = {24'd0, cyc};
                         default: rdata = 32'd0;
                     endcase
        endcase
    end
endmodule
