// soc_timer.sv — correct store encodings
`timescale 1ns/1ps

module soc_timer;
    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    logic [31:0] imem_addr, imem_rdata;
    logic        dmem_we;
    logic [31:0] dmem_addr, dmem_wdata, dmem_rdata;
    logic [3:0]  dmem_wstrb;

    logic [31:0] rom [0:31];
    integer i;
    initial begin
        // Verified encodings:
        // addi x1, x0, 10          = 0x00A00093
        // sw   x1, 16(x0)          = 0x00102823   ; timer compare @ 0x10
        // lw   x2, 12(x0)          = 0x00C02103   ; timer count  @ 0x0C
        // sw   x2, 0(x0)           = 0x00202023   ; UART @ 0x00 (just to show)
        // addi x3, x0, 1           = 0x00100193
        // sw   x3, 8(x0)           = 0x00302423   ; done @ 0x08
        // jal  x0, 0               = 0x0000006F
        rom[0] = 32'h00A00093;
        rom[1] = 32'h00102823; // sw x1, 16(x0)
        rom[2] = 32'h00C02103; // lw x2, 12(x0)
        rom[3] = 32'h00202023; // sw x2, 0(x0)
        rom[4] = 32'h00100193;
        rom[5] = 32'h00302423; // sw x3, 8(x0)
        rom[6] = 32'h0000006F;
        for (i = 7; i < 32; i++) rom[i] = 32'h00000013;
    end

    assign imem_rdata = rom[imem_addr[6:2]];

    // Map to simple offsets
    logic tcount_sel, tcmp_sel, done_sel, uart_sel;
    assign tcount_sel = (dmem_addr == 32'h0C);
    assign tcmp_sel   = (dmem_addr == 32'h10);
    assign done_sel   = (dmem_addr == 32'h08);
    assign uart_sel   = (dmem_addr == 32'h00);

    logic [31:0] timer_count, timer_cmp, last_uart;
    logic        done;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            timer_count <= 0;
            timer_cmp   <= 0;
            done        <= 0;
            last_uart   <= 0;
        end else begin
            timer_count <= timer_count + 1;
            if (dmem_we && tcmp_sel) timer_cmp <= dmem_wdata;
            if (dmem_we && done_sel) done <= 1;
            if (dmem_we && uart_sel) last_uart <= dmem_wdata;
        end
    end

    always @(*) dmem_rdata = tcount_sel ? timer_count : 32'h0;

    single_cycle_cpu cpu (
        .clk, .rst_n,
        .imem_addr, .imem_rdata,
        .dmem_we, .dmem_addr, .dmem_wdata, .dmem_wstrb, .dmem_rdata
    );

    initial begin
        rst_n = 0; #20; rst_n = 1;
        repeat (20) @(posedge clk);
        $display("timer_count=%0d timer_cmp=%0d last_uart=%0d done=%b",
                 timer_count, timer_cmp, last_uart, done);
        if (timer_cmp == 10 && done)
            $display("SOC+TIMER: PASSED");
        else
            $display("SOC+TIMER: FAILED");
        $finish;
    end
endmodule
