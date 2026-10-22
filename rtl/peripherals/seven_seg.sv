// seven_seg.sv — memory-mapped single-digit 7-segment display driver.
// Register block (byte offsets, word aligned):
//   0x0 VALUE  RW  [3:0] hex digit 0..F, [4] blank (all segments off),
//                  [7] decimal point. A write with wstrb[0] (sb or sw)
//                  latches wdata[7:0]. Reset = 0x10 (blank).
//   0x4 SEGS   RO  {24'b0, dp, seg[6:0]} — the pattern on the pins
// Outputs are active high: seg[0]=a, [1]=b, [2]=c, [3]=d, [4]=e, [5]=f, [6]=g
//
//        aaa
//       f   b
//        ggg
//       e   c
//        ddd  dp
module seven_seg (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        sel,
    input  logic        we,
    input  logic [3:0]  wstrb,
    input  logic [3:0]  addr,
    input  logic [31:0] wdata,
    output logic [31:0] rdata,
    output logic [6:0]  seg,       // {g,f,e,d,c,b,a}
    output logic        dp,
    output logic [3:0]  digit,     // latched hex value (for debug / LEDs)
    output logic        wr_pulse   // 1 cycle after each VALUE write
);
    logic [7:0] value;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            value    <= 8'h10;
            wr_pulse <= 1'b0;
        end else begin
            wr_pulse <= 1'b0;
            if (sel && we && addr == 4'h0 && wstrb[0]) begin
                value    <= wdata[7:0];
                wr_pulse <= 1'b1;
            end
        end
    end

    function automatic logic [6:0] hex7(input logic [3:0] h);
        case (h)            //  gfedcba
            4'h0: hex7 = 7'b0111111;
            4'h1: hex7 = 7'b0000110;
            4'h2: hex7 = 7'b1011011;
            4'h3: hex7 = 7'b1001111;
            4'h4: hex7 = 7'b1100110;
            4'h5: hex7 = 7'b1101101;
            4'h6: hex7 = 7'b1111101;
            4'h7: hex7 = 7'b0000111;
            4'h8: hex7 = 7'b1111111;
            4'h9: hex7 = 7'b1101111;
            4'hA: hex7 = 7'b1110111;
            4'hB: hex7 = 7'b1111100;
            4'hC: hex7 = 7'b0111001;
            4'hD: hex7 = 7'b1011110;
            4'hE: hex7 = 7'b1111001;
            default: hex7 = 7'b1110001;  // F
        endcase
    endfunction

    assign digit = value[3:0];
    assign seg   = value[4] ? 7'b0 : hex7(value[3:0]);
    assign dp    = value[7];

    always @(*) begin
        case (addr)
            4'h0:    rdata = {24'd0, value};
            4'h4:    rdata = {24'd0, dp, seg};
            default: rdata = 32'd0;
        endcase
    end
endmodule
