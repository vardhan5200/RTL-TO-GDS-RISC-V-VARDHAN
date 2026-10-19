// tb_pipe_m.sv — longer wait
`timescale 1ns/1ps
module tb_pipe_m;
    logic clk=0, rst_n=0;
    always #5 clk=~clk;

    logic [31:0] imem_addr, imem_rdata;
    logic [31:0] rom [0:15];
    initial begin
        rom[0] = 32'h00600093;
        rom[1] = 32'h00700113;
        rom[2] = 32'h022081B3; // mul x3, x1, x2
        rom[3] = 32'h00000013;
    end
    assign imem_rdata = rom[imem_addr[5:2]];

    pipe_m dut (.*);

    int cycles=0;
    always @(posedge clk) if (rst_n) cycles<=cycles+1;

    initial begin
        rst_n=0; #20; rst_n=1;
        wait (dut.regs[3] != 0 || cycles > 80);
        $display("Final x3=%0d after %0d cycles", dut.regs[3], cycles);
        if (dut.regs[3] == 42)
            $display("PIPE+MUL: PASSED");
        else
            $display("PIPE+MUL: FAILED");
        $finish;
    end
endmodule
