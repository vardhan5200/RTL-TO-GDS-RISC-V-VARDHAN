// div_tb.sv
`timescale 1ns/1ps
module div_tb;
    logic clk=0, rst_n=0, start=0, done;
    logic [31:0] dividend, divisor, quotient, remainder;
    always #5 clk=~clk;

    div dut (.*);

    int cycles=0;
    always @(posedge clk) cycles<=cycles+1;

    initial begin
        rst_n=0; #20; rst_n=1;
        dividend=20; divisor=3;
        @(posedge clk); start=1;
        @(posedge clk); start=0;
        wait (done || cycles>100);
        $display("20 / 3 = %0d rem %0d", quotient, remainder);
        if (done && quotient==6 && remainder==2)
            $display("DIV: PASSED");
        else
            $display("DIV: FAILED");
        $finish;
    end
endmodule
