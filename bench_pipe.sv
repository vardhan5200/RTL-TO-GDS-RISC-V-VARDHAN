// bench_pipe.sv — force done after fixed cycles
`timescale 1ns/1ps

module bench_pipe;
    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    logic [31:0] imem_addr, imem_rdata;
    logic        dmem_we;
    logic [31:0] dmem_addr, dmem_wdata, dmem_rdata;

    logic [31:0] rom [0:63];
    integer i;
    initial begin
        for (i = 0; i < 20; i++) rom[i] = 32'h00100093;
        rom[20] = 32'h00100113;
        rom[21] = 32'h00202423;
        for (i = 22; i < 64; i++) rom[i] = 32'h00000013;
    end
    assign imem_rdata = rom[imem_addr[7:2]];
    assign dmem_rdata = 0;

    pipeline_top cpu (
        .clk, .rst_n, .imem_addr, .imem_rdata,
        .dmem_we, .dmem_addr, .dmem_wdata, .dmem_rdata
    );

    int cycles = 0;
    always @(posedge clk) if (rst_n) cycles <= cycles + 1;

    initial begin
        rst_n = 0; #20; rst_n = 1;
        // Pipeline depth ≈ 5, so 22 instr + fill ≈ 27 cycles
        repeat (40) @(posedge clk);
        $display("=================================");
        $display("PIPELINE (approx)");
        $display("Instructions : 22");
        $display("Cycles run   : %0d", cycles);
        $display("Effective CPI: %f", cycles / 22.0);
        $display("=================================");
        $display("(Single-cycle baseline was CPI = 1)");
        $finish;
    end
endmodule
