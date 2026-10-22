// seven_seg_tb.sv — unit test: every hex digit's segment pattern decodes
// back to the digit, blank / dp bits, sb-style byte write, read-back.
`timescale 1ns/1ps
module seven_seg_tb;
    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    logic sel = 0, we = 0; logic [3:0] wstrb = 0, addr = 0; logic [31:0] wdata = 0, rdata;
    logic [6:0] seg; logic dp, wr_pulse; logic [3:0] digit;
    seven_seg dut (.clk, .rst_n, .sel, .we, .wstrb, .addr, .wdata, .rdata, .seg, .dp, .digit, .wr_pulse);

    // independent decoder (same as the demo testbench): pattern -> char
    function automatic byte seg2chr(input logic [6:0] s);
        case (s)
            7'b0111111: return "0"; 7'b0000110: return "1"; 7'b1011011: return "2";
            7'b1001111: return "3"; 7'b1100110: return "4"; 7'b1101101: return "5";
            7'b1111101: return "6"; 7'b0000111: return "7"; 7'b1111111: return "8";
            7'b1101111: return "9"; 7'b1110111: return "A"; 7'b1111100: return "b";
            7'b0111001: return "C"; 7'b1011110: return "d"; 7'b1111001: return "E";
            7'b1110001: return "F"; 7'b0000000: return " ";
            default:    return "?";
        endcase
    endfunction

    int errors = 0;
    task automatic wr(logic [3:0] a, logic [3:0] st, logic [31:0] d);
        @(negedge clk); sel = 1; we = 1; addr = a; wstrb = st; wdata = d;
        @(negedge clk); sel = 0; we = 0;
    endtask
    localparam logic [8*16-1:0] HEX = "0123456789AbCdEF";   // packed: char d at [8*(15-d)+:8]
    int e0;

    initial begin
        #22 rst_n = 1;
        $display("seven_seg_tb");
        @(negedge clk);
        if (seg !== 7'b0) begin errors++; $display("  FAIL reset not blank (%b)", seg); end
        e0 = errors;
        for (int d = 0; d < 16; d++) begin
            wr(4'h0, 4'b0001, {24'h0, 4'h0, 4'(d)});
            if (seg2chr(seg) !== HEX[8*(15-d) +: 8] || digit !== d) begin
                errors++; $display("  FAIL digit %0d: seg=%b decodes '%c'", d, seg, seg2chr(seg));
            end
        end
        if (errors == e0) $display("  ok   all 16 hex patterns decode back");
        wr(4'h0, 4'b0001, 32'h85);                       // dp + 5
        if (!(dp && seg2chr(seg) == "5")) begin errors++; $display("  FAIL dp/5"); end
        wr(4'h0, 4'b0001, 32'h13);                       // blank
        if (seg !== 0) begin errors++; $display("  FAIL blank"); end
        wr(4'h0, 4'b0000, 32'h02);                       // no byte strobe -> ignored
        if (seg !== 0) begin errors++; $display("  FAIL write without wstrb[0] latched"); end
        wr(4'h0, 4'b0001, 32'h09090909);                 // sb-style replicated data
        @(negedge clk); addr = 4'h0; #1;
        if (rdata !== 32'h09) begin errors++; $display("  FAIL VALUE readback %08h", rdata); end
        addr = 4'h4; #1;
        if (rdata !== {24'h0, 1'b0, 7'b1101111}) begin errors++; $display("  FAIL SEGS readback %08h", rdata); end
        if (errors == e0) $display("  ok   dp / blank / strobe / read-back");
        if (errors == 0) $display("SEVEN_SEG TEST: PASS");
        else             $display("SEVEN_SEG TEST: FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
