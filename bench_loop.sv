// bench_loop.sv — debug from testbench
`timescale 1ns/1ps

module bench_loop;
    logic clk=0, rst_n=0;
    always #5 clk=~clk;

    logic [31:0] imem_addr, imem_rdata;
    logic dmem_we;
    logic [31:0] dmem_addr, dmem_wdata, dmem_rdata;

    logic [31:0] rom [0:15];
    initial begin
        rom[0] = 32'h00A00093; // addi x1, x0, 10
        rom[1] = 32'hFFF08093; // addi x1, x1, -1
        rom[2] = 32'hFE009EE3; // bne
        rom[3] = 32'h00100113; // addi x2, x0, 1
    end
    assign imem_rdata = rom[imem_addr[5:2]];
    assign dmem_rdata = 0;

    pipeline_branch cpu (.*);

    int cycles=0;
    always @(posedge clk) begin
        if (rst_n) cycles<=cycles+1;
        if (cycles < 15)
            $display("cyc=%0d PC=%h instr=%h x1=%0d", cycles, cpu.pc, imem_rdata, cpu.regs[1]);
    end

    initial begin
        rst_n=0; #20; rst_n=1;
        wait (cpu.regs[2]==1 || cycles>100);
        $display("DONE cycles=%0d x1=%0d x2=%0d", cycles, cpu.regs[1], cpu.regs[2]);
        $finish;
    end
endmodule
