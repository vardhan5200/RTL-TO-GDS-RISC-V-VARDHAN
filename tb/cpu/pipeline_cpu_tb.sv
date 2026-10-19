// pipeline_cpu_tb.sv — clean full test
`timescale 1ns/1ps
module pipeline_cpu_tb;
    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    logic [31:0] imem_addr, imem_rdata;
    logic dmem_we;
    logic [31:0] dmem_addr, dmem_wdata, dmem_rdata;
    logic [3:0] dmem_wstrb;

    logic [31:0] imem [0:15];
    initial begin
        imem[0] = 32'h00A00093; // addi x1, x0, 10
        imem[1] = 32'h01400113; // addi x2, x0, 20
        imem[2] = 32'h002081B3; // add  x3, x1, x2
        imem[3] = 32'h00302023; // sw   x3, 0(x0)
        imem[4] = 32'h00002203; // lw   x4, 0(x0)
        for (int i = 5; i < 16; i++)
            imem[i] = 32'h00000013;
    end
    assign imem_rdata = imem[imem_addr[5:2]];

    simple_memory u_dmem (
        .clk, .rst_n, .we(dmem_we),
        .addr(dmem_addr), .wdata(dmem_wdata), .wstrb(dmem_wstrb),
        .rdata(dmem_rdata)
    );

    pipeline_cpu dut (
        .clk, .rst_n,
        .imem_addr, .imem_rdata,
        .dmem_we, .dmem_addr, .dmem_wdata, .dmem_wstrb, .dmem_rdata
    );

    initial begin
        rst_n = 0; #20; rst_n = 1;
        repeat (15) @(posedge clk); #1;

        $display("x1=%0d x2=%0d x3=%0d x4=%0d mem0=%0d",
                 dut.u_rf.regs[1], dut.u_rf.regs[2],
                 dut.u_rf.regs[3], dut.u_rf.regs[4], u_dmem.mem[0]);

        if (dut.u_rf.regs[1]==10 && dut.u_rf.regs[2]==20 &&
            dut.u_rf.regs[3]==30 && dut.u_rf.regs[4]==30 && u_dmem.mem[0]==30)
            $display("PIPELINE: PASSED");
        else
            $display("PIPELINE: FAILED");
        $finish;
    end
endmodule
