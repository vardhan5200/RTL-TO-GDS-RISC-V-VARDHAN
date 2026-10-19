// soc.sv — slightly richer SoC
// Regions:
//   0x00000000 - 0x000000FF  Boot ROM (read-only)
//   0x00000100 - 0x000001FF  SRAM
//   0x00000200               UART TX
//   0x00000204               GPIO out
//   0x00000208               Done flag
`timescale 1ns/1ps

module soc;
    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    logic [31:0] imem_addr, imem_rdata;
    logic        dmem_we;
    logic [31:0] dmem_addr, dmem_wdata, dmem_rdata;
    logic [3:0]  dmem_wstrb;

    // Boot ROM + SRAM
    logic [31:0] rom [0:63];
    logic [31:0] sram [0:63];
    integer i;

    initial begin
        // Boot program:
        //   addi x1, x0, 0x48     ; 'H'
        //   sw   x1, 0x200(x0)    ; UART
        //   addi x1, x0, 0x69     ; 'i'
        //   sw   x1, 0x200(x0)
        //   addi x2, x0, 0x55     ; GPIO pattern
        //   sw   x2, 0x204(x0)    ; GPIO
        //   addi x3, x0, 1
        //   sw   x3, 0x208(x0)    ; done
        //   jal  x0, 0
        rom[0] = 32'h04800093; // addi x1, x0, 'H'
        rom[1] = 32'h20102023; // sw   x1, 0x200(x0)
        rom[2] = 32'h06900093; // addi x1, x0, 'i'
        rom[3] = 32'h20102023; // sw   x1, 0x200(x0)
        rom[4] = 32'h05500113; // addi x2, x0, 0x55
        rom[5] = 32'h20202223; // sw   x2, 0x204(x0)
        rom[6] = 32'h00100193; // addi x3, x0, 1
        rom[7] = 32'h20302423; // sw   x3, 0x208(x0)
        rom[8] = 32'h0000006F; // jal  x0, 0
        for (i = 9; i < 64; i++) rom[i] = 32'h00000013;
        for (i = 0; i < 64; i++) sram[i] = 32'h0;
    end

    // Instruction fetch from ROM
    assign imem_rdata = rom[imem_addr[7:2]];

    // Data decode
    logic rom_sel, sram_sel, uart_sel, gpio_sel, done_sel;
    assign rom_sel  = (dmem_addr[31:8] == 24'h0);
    assign sram_sel = (dmem_addr[31:8] == 24'h1);
    assign uart_sel = (dmem_addr == 32'h200);
    assign gpio_sel = (dmem_addr == 32'h204);
    assign done_sel = (dmem_addr == 32'h208);

    logic [31:0] rom_rdata, sram_rdata;
    assign rom_rdata  = rom[dmem_addr[7:2]];
    assign sram_rdata = sram[dmem_addr[7:2]];

    always @(*) begin
        if (rom_sel)       dmem_rdata = rom_rdata;
        else if (sram_sel) dmem_rdata = sram_rdata;
        else               dmem_rdata = 32'h0;
    end

    logic [7:0] uart_byte;
    logic [7:0] gpio_out;
    logic       done;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            uart_byte <= 0;
            gpio_out  <= 0;
            done      <= 0;
        end else if (dmem_we) begin
            if (uart_sel) begin
                uart_byte <= dmem_wdata[7:0];
                $display("UART: %c", dmem_wdata[7:0]);
            end
            if (gpio_sel) begin
                gpio_out <= dmem_wdata[7:0];
                $display("GPIO: %h", dmem_wdata[7:0]);
            end
            if (done_sel)
                done <= 1;
            if (sram_sel)
                sram[dmem_addr[7:2]] <= dmem_wdata;
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
        wait (done);
        #10;
        $display("Final UART='%c' GPIO=%h done=%b", uart_byte, gpio_out, done);
        if (uart_byte == "i" && gpio_out == 8'h55 && done)
            $display("SOC: PASSED");
        else
            $display("SOC: FAILED");
        $finish;
    end
endmodule
