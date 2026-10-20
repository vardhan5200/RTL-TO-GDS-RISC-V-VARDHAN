// mul_rand_tb.sv — random + corner vectors for rtl/cpu/mul.sv vs a*b; also checks
// the result is held after done (result is the accumulator register).
`timescale 1ns/1ps
module mul_rand_tb;
    logic clk=0, rst_n=0, start=0, done; logic [31:0] a, b, result;
    always #5 clk=~clk;
    mul dut (.*);
    int errors=0, n=0;
    task automatic run(logic [31:0] x, logic [31:0] y);
        logic [31:0] exp; exp = x * y;
        @(negedge clk); a=x; b=y; start=1; @(negedge clk); start=0; a='x; b='x;
        while (!done) @(negedge clk);
        n++; if (result !== exp) begin errors++; $display("FAIL %h*%h got %h exp %h", x, y, result, exp); end
        repeat ($urandom%3) @(negedge clk);
        if (result !== exp) begin errors++; $display("FAIL hold %h*%h", x, y); end
    endtask
    initial begin
        #22 rst_n=1;
        run(6,7); run(0,0); run(32'hffffffff,32'hffffffff); run(32'h80000000,2); run(1,32'hdeadbeef);
        for (int k=0;k<500;k++) run($urandom,$urandom);
        $display("MUL_RAND: %0d vectors, %0d errors", n, errors);
        if (errors==0) $display("MUL_RAND: ALL TESTS PASSED"); else $display("MUL_RAND: FAILED");
        $finish;
    end
endmodule
