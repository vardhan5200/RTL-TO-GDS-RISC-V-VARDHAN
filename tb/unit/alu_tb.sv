// alu_tb.sv — unit test for alu.sv
`timescale 1ns/1ps

module alu_tb;
    logic [31:0] a, b, y;
    logic [3:0]  op;
    logic        zero;

    alu dut (.a(a), .b(b), .op(op), .y(y), .zero(zero));

    int errors = 0;

    task check(input [31:0] exp, input string name);
        if (y !== exp) begin
            $display("FAIL %s: got %h expected %h", name, y, exp);
            errors++;
        end else $display("PASS %s", name);
    endtask

    initial begin
        // ADD
        a = 32'd10; b = 32'd20; op = 4'd0; #1; check(32'd30, "ADD");
        // SUB
        a = 32'd50; b = 32'd20; op = 4'd1; #1; check(32'd30, "SUB");
        // AND
        a = 32'hFF00; b = 32'h0FF0; op = 4'd2; #1; check(32'h0F00, "AND");
        // OR
        a = 32'hFF00; b = 32'h00FF; op = 4'd3; #1; check(32'hFFFF, "OR");
        // XOR
        a = 32'hAAAA; b = 32'h5555; op = 4'd4; #1; check(32'hFFFF, "XOR");
        // SLL
        a = 32'd1; b = 32'd4; op = 4'd5; #1; check(32'd16, "SLL");
        // SRL
        a = 32'h80000000; b = 32'd1; op = 4'd6; #1; check(32'h40000000, "SRL");
        // SRA
        a = 32'h80000000; b = 32'd1; op = 4'd7; #1; check(32'hC0000000, "SRA");
        // SLT (signed)
        a = -32'sd5; b = 32'sd3; op = 4'd8; #1; check(32'd1, "SLT neg");
        a = 32'sd5; b = -32'sd3; op = 4'd8; #1; check(32'd0, "SLT pos");
        // SLTU
        a = 32'hFFFFFFFF; b = 32'd1; op = 4'd9; #1; check(32'd0, "SLTU");
        a = 32'd1; b = 32'hFFFFFFFF; op = 4'd9; #1; check(32'd1, "SLTU small");

        if (errors == 0) $display("ALU: ALL TESTS PASSED");
        else $display("ALU: %0d FAILURES", errors);
        $finish;
    end
endmodule
