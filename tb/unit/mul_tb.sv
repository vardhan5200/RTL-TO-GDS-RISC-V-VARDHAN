// mul_tb.sv — with timeout
`timescale 1ns/1ps
module mul_tb;
    logic clk=0, rst_n=0, start=0, done;
    logic [31:0] a, b, result;
    always #5 clk=~clk;

    mul dut (.*);

    int cycles=0;
    always @(posedge clk) cycles<=cycles+1;

    initial begin
        rst_n=0; #20; rst_n=1;
        a=6; b=7;
        @(posedge clk); start=1;
        @(posedge clk); start=0;
        wait (done || cycles>100);
        if (done && result==42)
            $display("MUL: PASSED (6*7=42)");
        else
            $display("MUL: FAILED result=%0d done=%b cycles=%0d", result, done, cycles);
        $finish;
    end
endmodule
