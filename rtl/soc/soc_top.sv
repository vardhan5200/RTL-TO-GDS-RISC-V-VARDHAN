// soc_top.sv — Integrated SoC top: single_cycle_cpu + ROM + SRAM + UART/GPIO/
// DONE + timer + interrupt controller, all routed through addr_decode.
// Same address map as soc.sv (ROM/SRAM/UART/GPIO/DONE unchanged), plus timer
// and irq controller. See docs/memory_map.md and rtl/soc/soc_map_pkg.sv.
//
// The ROM image is loaded by the testbench (hierarchical write to dut.rom)
// or from ROM_FILE with $readmemh when ROM_FILE is non-empty.
//
// irq: exposed as a port only. single_cycle_cpu has no CSR/trap logic yet,
// so the CPU does not take interrupts; software can poll IRQ PENDING/CLAIM.
import soc_map_pkg::*;

module soc_top #(
    parameter string ROM_FILE = ""
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic [6:0]  ext_irq,      // irq sources 1..7 (tie 0 if unused)
    output logic        irq,          // to CPU (machine external interrupt)
    output logic [7:0]  uart_byte,
    output logic        uart_valid,   // 1-cycle pulse per UART write
    output logic [7:0]  gpio_out,
    output logic        done,
    output logic        bus_err,      // sticky: unmapped access / ROM write
    output logic [31:0] bus_err_addr  // address of the first bus error
);
    logic [31:0] imem_addr, imem_rdata;
    logic        dmem_we, dmem_re;
    logic [31:0] dmem_addr, dmem_wdata, dmem_rdata;
    logic [3:0]  dmem_wstrb;

    single_cycle_cpu cpu (
        .clk, .rst_n,
        .imem_addr, .imem_rdata,
        .dmem_we, .dmem_addr, .dmem_wdata, .dmem_wstrb, .dmem_rdata
    );

    // The CPU does not export mem_read; derive it from the LOAD opcode so
    // unmapped *reads* can be flagged (dmem_addr is the ALU result on
    // non-memory instructions and must not be checked then).
    assign dmem_re = (imem_rdata[6:0] == 7'b0000011);

    // ---------------- Memories ----------------
    logic [31:0] rom  [0:63];
    logic [31:0] sram [0:63];
    initial begin
        for (int i = 0; i < 64; i++) begin
            rom[i]  = 32'h0000_0013;  // nop
            sram[i] = 32'h0;
        end
        if (ROM_FILE != "") $readmemh(ROM_FILE, rom);
    end

    // Instruction fetch: ROM only (fetch outside ROM returns nop)
    assign imem_rdata = (imem_addr < ROM_BASE + ROM_SIZE) ? rom[imem_addr[7:2]]
                                                          : 32'h0000_0013;

    // ---------------- Decode ----------------
    // soc_top (legacy single-cycle SoC) does not implement the UART register
    // block or main RAM: those regions are treated as unmapped here.
    logic rom_sel, sram_sel, uart_sel, gpio_sel, done_sel, timer_sel, irq_sel;
    logic uartb_sel, mem_sel, dec_unmapped, unmapped;
    addr_decode u_dec (
        .addr(dmem_addr),
        .rom_sel, .sram_sel, .uart_sel, .gpio_sel, .done_sel,
        .timer_sel, .irq_sel, .uartb_sel, .mem_sel, .unmapped(dec_unmapped)
    );
    assign unmapped = dec_unmapped || uartb_sel || mem_sel;

    // ---------------- Timer + IRQ controller ----------------
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

    // ---------------- Read mux ----------------
    always @(*) begin
        if      (rom_sel)   dmem_rdata = rom[dmem_addr[7:2]];
        else if (sram_sel)  dmem_rdata = sram[dmem_addr[7:2]];
        else if (gpio_sel)  dmem_rdata = {24'd0, gpio_out};
        else if (done_sel)  dmem_rdata = {31'd0, done};
        else if (timer_sel) dmem_rdata = timer_rdata;
        else if (irq_sel)   dmem_rdata = irq_rdata;
        else                dmem_rdata = 32'h0;   // UART TX and unmapped read 0
    end

    // ---------------- Writes / simple peripherals / bus error ----------------
    logic err_now;
    assign err_now = (unmapped && (dmem_we || dmem_re)) || (rom_sel && dmem_we);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            uart_byte    <= 8'd0;
            uart_valid   <= 1'b0;
            gpio_out     <= 8'd0;
            done         <= 1'b0;
            bus_err      <= 1'b0;
            bus_err_addr <= 32'd0;
        end else begin
            uart_valid <= dmem_we && uart_sel;
            if (dmem_we && uart_sel) uart_byte <= dmem_wdata[7:0];
            if (dmem_we && gpio_sel) gpio_out  <= dmem_wdata[7:0];
            if (dmem_we && done_sel) done      <= 1'b1;
            if (dmem_we && sram_sel) sram[dmem_addr[7:2]] <= dmem_wdata;
            if (err_now && !bus_err) begin
                bus_err      <= 1'b1;
                bus_err_addr <= dmem_addr;
            end
        end
    end
endmodule
