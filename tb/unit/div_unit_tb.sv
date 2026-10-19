// div_unit_tb.sv — self-checking: DIV/DIVU/REM/REMU (div_unit + div.sv)
// against a reference model, incl. RISC-V corner cases and random operands.
`timescale 1ns/1ps
module div_unit_tb;
    logic clk = 0, rst_n = 0, start = 0, done;
    logic [1:0]  op;
    logic [31:0] a, b, result;
    always #5 clk = ~clk;
    div_unit dut (.*);

    function automatic logic [31:0] ref_model(logic [1:0] o, logic [31:0] x, logic [31:0] y);
        logic signed [31:0] sx, sy, sq, sr; sx = x; sy = y;
        if (y == 0) return o[1] ? x : 32'hFFFF_FFFF;
        if (!o[0] && x == 32'h8000_0000 && y == 32'hFFFF_FFFF) return o[1] ? 32'h0 : x;
        sq = sx / sy; sr = sx % sy;    // signed ops in a purely signed context
        case (o)
            2'b00: return sq;
            2'b01: return x / y;
            2'b10: return sr;
            default: return x % y;
        endcase
    endfunction

    int errors = 0, n = 0, lat = 0;
    task automatic run(logic [1:0] o, logic [31:0] x, logic [31:0] y);
        logic [31:0] exp; int c;
        exp = ref_model(o, x, y);
        @(negedge clk); op = o; a = x; b = y; start = 1;
        @(negedge clk); start = 0; c = 1;
        while (!done) begin @(negedge clk); c++; end
        lat = c; n++;
        if (result !== exp) begin
            errors++;
            $display("  FAIL op=%0d a=%08h b=%08h got %08h exp %08h", o, x, y, result, exp);
        end
    endtask

    initial begin
        #22 rst_n = 1;
        for (int o = 0; o < 4; o++) begin
            run(o, 20, 3); run(o, -20, 3); run(o, 20, -3); run(o, -20, -3);
            run(o, 7, 0); run(o, -7, 0); run(o, 0, 0); run(o, 32'h8000_0000, 32'hFFFF_FFFF);
            run(o, 32'hFFFF_FFFF, 1); run(o, 32'hFFFF_FFFF, 32'hFFFF_FFFF); run(o, 5, 7);
            run(o, 32'h8000_0000, 1); run(o, 32'h7FFF_FFFF, 2);
        end
        for (int k = 0; k < 400; k++) run($urandom % 4, $urandom, (k % 3 == 0) ? ($urandom % 50) : $urandom);
        $display("DIV_UNIT: %0d vectors, %0d errors, %0d cycles start->done", n, errors, lat);
        if (errors == 0) $display("DIV_UNIT: ALL TESTS PASSED"); else $display("DIV_UNIT: FAILED");
        $finish;
    end
endmodule
