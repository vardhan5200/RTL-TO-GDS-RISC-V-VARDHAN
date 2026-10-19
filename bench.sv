// bench.sv — fixed-iteration benchmark (no branch)
`timescale 1ns/1ps

module bench;
    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    logic [31:0] imem_addr, imem_rdata;
    logic        dmem_we;
    logic [31:0] dmem_addr, dmem_wdata, dmem_rdata;
    logic [3:0]  dmem_wstrb;

    logic [31:0] rom [0:63];
    integer i;
    initial begin
        // 20 simple addi instructions, then write done
        for (i = 0; i < 20; i++)
            rom[i] = 32'h00100093;          // addi x1, x0, 1
        rom[20] = 32'h00100113;             // addi x2, x0, 1
        rom[21] = 32'h00202423;             // sw   x2, 8(x0)  ; done
        rom[22] = 32'h0000006F;             // jal  x0, 0
        for (i = 23; i < 64; i++)
            rom[i] = 32'h00000013;
    end

    assign imem_rdata = rom[imem_addr[7:2]];

    logic done;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) done <= 0;
        else if (dmem_we && dmem_addr == 32'h08) done <= 1;
    end
    assign dmem_rdata = 32'h0;

    single_cycle_cpu cpu (
        .clk, .rst_n,
        .imem_addr, .imem_rdata,
        .dmem_we, .dmem_addr, .dmem_wdata, .dmem_wstrb, .dmem_rdata
    );

    int cycles = 0;
    always @(posedge clk) if (rst_n && !done) cycles <= cycles + 1;

    initial begin
        rst_n = 0; #20; rst_n = 1;
        wait (done);
        $display("=================================");
        $display("Instructions executed : 22");
        $display("Total cycles          : %0d", cycles);
        $display("CPI (single-cycle)    : %0d", cycles / 22);
        $display("=================================");
        $display("BASELINE recorded.");
        $finish;
    end
endmodule
