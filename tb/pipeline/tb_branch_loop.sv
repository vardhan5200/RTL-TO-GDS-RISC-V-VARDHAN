// tb_branch_loop.sv — self-checking: BNE loop must iterate 10 times.
//   0x00 addi x1, x0, 10
//   0x04 loop: addi x1, x1, -1
//   0x08 bne  x1, x0, loop
//   0x0C addi x2, x0, 1
`timescale 1ns/1ps
module tb_branch_loop;
    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    logic [31:0] imem_addr, imem_rdata, dmem_addr, dmem_wdata, dmem_rdata;
    logic        dmem_we;
    logic [31:0] rom [0:15];
    initial begin
        rom[0] = 32'h00A00093; // addi x1, x0, 10
        rom[1] = 32'hFFF08093; // addi x1, x1, -1
        rom[2] = 32'hFE009EE3; // bne  x1, x0, -4
        rom[3] = 32'h00100113; // addi x2, x0, 1
        for (int i = 4; i < 16; i++) rom[i] = 32'h00000013;
    end
    assign imem_rdata = rom[imem_addr[5:2]];
    assign dmem_rdata = 32'h0;

    pipeline_branch dut (.*);

    int cycles = 0, retired = 0, taken = 0, bne_exec = 0, x2_early = 0;
    always @(posedge clk) if (rst_n) begin
        cycles <= cycles + 1;
        if (dut.retire) retired <= retired + 1;
        if (dut.retire && dut.branch_ex) bne_exec <= bne_exec + 1;
        if (dut.flush) taken <= taken + 1;
        if (dut.regs[2] == 1 && dut.regs[1] != 0) x2_early <= 1; // wrong-path leak
    end

    initial begin
        rst_n = 0; #20; rst_n = 1;
        wait (dut.regs[2] == 1 || cycles > 200);
        #1;
        $display("BRANCH LOOP: x1=%0d x2=%0d cycles=%0d retired=%0d bne_exec=%0d taken=%0d CPI=%0.3f",
                 dut.regs[1], dut.regs[2], cycles, retired, bne_exec, taken,
                 real'(cycles) / real'(retired));
        if (dut.regs[1] == 0 && dut.regs[2] == 1 && cycles > 15 && retired == 22 &&
            bne_exec == 10 && taken == 9 && !x2_early)
            $display("BRANCH LOOP: PASS");
        else
            $display("BRANCH LOOP: FAIL");
        $finish;
    end
endmodule
