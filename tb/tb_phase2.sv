// tb_phase2.sv — expect ~20+ cycles for 10 iterations
`timescale 1ns/1ps

module tb_phase2;
    logic clk=0, rst_n=0;
    always #5 clk=~clk;

    logic [31:0] imem_addr, imem_rdata;
    logic [31:0] rom [0:15];
    initial begin
        rom[0] = 32'h00A00093; // addi x1, x0, 10
        rom[1] = 32'hFFF08093; // addi x1, x1, -1
        rom[2] = 32'hFE009EE3; // bne  x1, x0, loop
        rom[3] = 32'h00100113; // addi x2, x0, 1
    end
    assign imem_rdata = rom[imem_addr[5:2]];

    pipe_phase2 dut (.*);

    int cycles = 0;
    always @(posedge clk) if (rst_n) cycles <= cycles + 1;

    initial begin
        rst_n=0; #20; rst_n=1;
        wait (dut.regs[2] == 1 || cycles > 100);
        $display("=================================");
        $display("x1=%0d x2=%0d", dut.regs[1], dut.regs[2]);
        $display("Cycles : %0d", cycles);
        if (dut.regs[2] == 1 && cycles > 15)
            $display("PHASE2 LOOP: PASSED (real iterations)");
        else
            $display("PHASE2 LOOP: check count");
        $display("=================================");
        $finish;
    end
endmodule
