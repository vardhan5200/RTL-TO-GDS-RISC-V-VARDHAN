// soc_core_top.sv — SoC with the integrated core (rtl/core/core_top.sv):
// same memory map / peripherals as soc_top.sv (ROM, SRAM, UART, GPIO, DONE,
// timer, irq_ctrl via addr_decode), but the CPU is the pipelined core with
// D-cache + M-mode trap unit, and irq_ctrl.irq drives the core's meip.
// ROM + SRAM (< 0x200) are cacheable; peripherals are uncached.
import soc_map_pkg::*;

module soc_core_top #(
    parameter string ROM_FILE = "",
    parameter bit    USE_MMU  = 1'b0
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic [6:0]  ext_irq,
    output logic        irq,
    output logic [7:0]  uart_byte,
    output logic        uart_valid,
    output logic [7:0]  gpio_out,
    output logic        done,
    output logic        bus_err,
    output logic [31:0] bus_err_addr
);
    logic [31:0] imem_addr, imem_rdata;
    logic        dmem_we, dmem_re, mmu_fault;
    logic [31:0] dmem_addr, dmem_wdata, dmem_rdata;
    logic [3:0]  dmem_wstrb;

    core_top #(.CACHE_BASE(ROM_BASE), .CACHE_LIMIT(SRAM_BASE + SRAM_SIZE), .USE_MMU(USE_MMU)) core (
        .clk, .rst_n,
        .imem_addr, .imem_rdata,
        .dmem_re, .dmem_we, .dmem_addr, .dmem_wdata, .dmem_wstrb, .dmem_rdata,
        .meip(irq), .mtip(1'b0), .msip(1'b0),
        .satp(32'h0), .priv_mode(2'b11), .mmu_fault
    );

    logic [31:0] rom  [0:63];
    logic [31:0] sram [0:63];
    initial begin
        for (int i = 0; i < 64; i++) begin
            rom[i]  = 32'h0000_0013;
            sram[i] = 32'h0;
        end
        if (ROM_FILE != "") $readmemh(ROM_FILE, rom);
    end

    assign imem_rdata = (imem_addr < ROM_BASE + ROM_SIZE) ? rom[imem_addr[7:2]]
                                                          : 32'h0000_0013;

    logic rom_sel, sram_sel, uart_sel, gpio_sel, done_sel, timer_sel, irq_sel, unmapped;
    addr_decode u_dec (
        .addr(dmem_addr),
        .rom_sel, .sram_sel, .uart_sel, .gpio_sel, .done_sel,
        .timer_sel, .irq_sel, .unmapped
    );

    logic [31:0] timer_rdata, irq_rdata;
    logic        timer_irq;
    timer u_timer (
        .clk, .rst_n,
        .sel(timer_sel), .we(dmem_we), .addr(dmem_addr[3:0]),
        .wdata(dmem_wdata), .rdata(timer_rdata), .irq(timer_irq)
    );
    irq_ctrl #(.N(8)) u_irq (
        .clk, .rst_n,
        .sel(irq_sel), .we(dmem_we), .addr(dmem_addr[3:0]),
        .wdata(dmem_wdata), .rdata(irq_rdata),
        .src({ext_irq, timer_irq}),
        .irq(irq)
    );

    always @(*) begin
        if      (rom_sel)   dmem_rdata = rom[dmem_addr[7:2]];
        else if (sram_sel)  dmem_rdata = sram[dmem_addr[7:2]];
        else if (gpio_sel)  dmem_rdata = {24'd0, gpio_out};
        else if (done_sel)  dmem_rdata = {31'd0, done};
        else if (timer_sel) dmem_rdata = timer_rdata;
        else if (irq_sel)   dmem_rdata = irq_rdata;
        else                dmem_rdata = 32'h0;
    end

    logic err_now;
    assign err_now = (unmapped && (dmem_we || dmem_re)) || (rom_sel && dmem_we);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            uart_byte <= 8'd0; uart_valid <= 1'b0; gpio_out <= 8'd0; done <= 1'b0;
            bus_err <= 1'b0; bus_err_addr <= 32'd0;
        end else begin
            uart_valid <= dmem_we && uart_sel;
            if (dmem_we && uart_sel) uart_byte <= dmem_wdata[7:0];
            if (dmem_we && gpio_sel) gpio_out  <= dmem_wdata[7:0];
            if (dmem_we && done_sel) done      <= 1'b1;
            if (dmem_we && sram_sel)
                for (int b = 0; b < 4; b++)
                    if (dmem_wstrb[b]) sram[dmem_addr[7:2]][8*b +: 8] <= dmem_wdata[8*b +: 8];
            if (err_now && !bus_err) begin
                bus_err <= 1'b1; bus_err_addr <= dmem_addr;
            end
        end
    end
endmodule
