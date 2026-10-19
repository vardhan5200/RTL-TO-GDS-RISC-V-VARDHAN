// soc_min.sv — fixed address decode
`timescale 1ns/1ps

module soc_min;
    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    logic [31:0] imem_addr, imem_rdata;
    logic        dmem_we;
    logic [31:0] dmem_addr, dmem_wdata, dmem_rdata;
    logic [3:0]  dmem_wstrb;

    logic [31:0] mem [0:255];
    integer i;
    initial begin
        mem[0] = 32'h04100093; // addi x1, x0, 0x41
        mem[1] = 32'h20102023; // sw   x1, 0x200(x0)
        mem[2] = 32'h00100113; // addi x2, x0, 1
        mem[3] = 32'h20202223; // sw   x2, 0x204(x0)
        mem[4] = 32'h0000006F; // jal  x0, 0
        for (i = 5; i < 256; i++) mem[i] = 32'h00000013;
    end

    assign imem_rdata = mem[imem_addr[9:2]];

    // Tight decode
    logic uart_sel, flag_sel;
    assign uart_sel = (dmem_addr == 32'h200);
    assign flag_sel = (dmem_addr == 32'h204);

    assign dmem_rdata = 32'h0;

    logic [7:0] uart_tx;
    logic       done_flag;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            done_flag <= 0;
            uart_tx   <= 0;
        end else begin
            if (dmem_we && uart_sel) begin
                uart_tx <= dmem_wdata[7:0];
                $display("UART: %c", dmem_wdata[7:0]);
            end
            if (dmem_we && flag_sel)
                done_flag <= 1;
        end
    end

    single_cycle_cpu cpu (
        .clk, .rst_n,
        .imem_addr, .imem_rdata,
        .dmem_we, .dmem_addr, .dmem_wdata, .dmem_wstrb, .dmem_rdata
    );

    initial begin
        rst_n = 0;
        #20 rst_n = 1;
        wait (done_flag);
        #10;
        $display("SOC: UART sent '%c', done=%b", uart_tx, done_flag);
        if (uart_tx == 8'h41 && done_flag)
            $display("MIN SOC: PASSED");
        else
            $display("MIN SOC: FAILED");
        $finish;
    end
endmodule
