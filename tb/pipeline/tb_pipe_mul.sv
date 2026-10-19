// tb_pipe_mul.sv — self-checking: MUL through the pipeline (rtl/cpu/mul.sv).
//   addi x1, x0, 6
//   addi x2, x0, 7
//   mul  x3, x1, x2      ; back-to-back RAW on x1/x2 (forwarding) -> 42
//   addi x4, x3, 1       ; RAW on MUL result right after the stall -> 43
//   addi x5, x0, 5       ; must not be lost/duplicated by the stall
`timescale 1ns/1ps
module tb_pipe_mul;
    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    logic [31:0] imem_addr, imem_rdata, dmem_addr, dmem_wdata, dmem_rdata;
    logic        dmem_we;
    logic [31:0] rom [0:15];
    initial begin
        rom[0] = 32'h00600093; // addi x1, x0, 6
        rom[1] = 32'h00700113; // addi x2, x0, 7
        rom[2] = 32'h022081B3; // mul  x3, x1, x2
        rom[3] = 32'h00118213; // addi x4, x3, 1
        rom[4] = 32'h00500293; // addi x5, x0, 5
        for (int i = 5; i < 16; i++) rom[i] = 32'h00000013;
    end
    assign imem_rdata = rom[imem_addr[5:2]];
    assign dmem_rdata = 32'h0;

    pipeline_branch dut (.*);

    int cycles = 0;
    always @(posedge clk) if (rst_n) cycles <= cycles + 1;

    initial begin
        rst_n = 0; #20; rst_n = 1;
        wait (dut.regs[5] == 5 || cycles > 200);
        #1;
        $display("PIPE+MUL: x1=%0d x2=%0d x3=%0d x4=%0d x5=%0d cycles=%0d",
                 dut.regs[1], dut.regs[2], dut.regs[3], dut.regs[4], dut.regs[5], cycles);
        if (dut.regs[1] == 6 && dut.regs[2] == 7 && dut.regs[3] == 42 &&
            dut.regs[4] == 43 && dut.regs[5] == 5)
            $display("PIPE+MUL: PASS");
        else
            $display("PIPE+MUL: FAIL");
        $finish;
    end
endmodule
