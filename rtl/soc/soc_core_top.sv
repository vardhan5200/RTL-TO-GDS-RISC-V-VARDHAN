// soc_core_top.sv — SoC with the integrated core (rtl/core/core_top.sv):
// same memory map / peripherals as soc_top.sv (ROM, SRAM, UART, GPIO, DONE,
// timer, irq_ctrl via addr_decode), but the CPU is the pipelined core with
// D-cache + M-mode trap unit, and irq_ctrl.irq drives the core's meip.
// ROM + SRAM (< 0x200) are cacheable; peripherals and main RAM are uncached.
//
// Program loading / reset (reset vector = 0x0000_0000, Boot ROM):
//   * ROM image: parameter ROM_FILE or plusarg +ROM_HEX=<file> ($readmemh,
//     one 32-bit word per line, word 0 = address 0x0).
//   * Main RAM image (64 KiB at 0x0001_0000, code + data + stack): parameter
//     MEM_FILE or plusarg +MEM_HEX=<file> (word 0 = address 0x0001_0000).
//   * If a RAM image is given and no ROM image, the Boot ROM holds a 2-word
//     stub at the reset vector that jumps to MEM_BASE:
//       0x000: lui  t0, 0x10      # t0 = 0x0001_0000
//       0x004: jalr x0, 0(t0)
//   Plusargs override the parameters. Instruction fetch is served from the
//   Boot ROM and from main RAM; anything else fetches a NOP.
// UART: register block at 0x230 (see rtl/soc/uart.sv) + legacy TX alias 0x200.
// uart_tx / uart_rx are 8N1 serial lines (BAUDDIV clocks per bit);
// uart_byte / uart_valid are a sim tap pulsing when a byte enters the TX FIFO.
import soc_map_pkg::*;

module soc_core_top #(
    parameter string ROM_FILE = "",
    parameter string MEM_FILE = "",
    parameter bit    USE_MMU  = 1'b0,
    parameter int    UART_DIV = 16
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic [6:0]  ext_irq,
    output logic        irq,
    output logic [7:0]  uart_byte,
    output logic        uart_valid,
    output logic        uart_tx,
    input  logic        uart_rx = 1'b1,
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
        .priv_mode(2'b11), .mmu_fault
    );

    logic [31:0] rom  [0:63];
    logic [31:0] sram [0:63];
    logic [31:0] mem  [0:MEM_WORDS-1];
    string rom_file, mem_file;
    int    n_mem;
    // number of words in a $readmemh file (so a short image does not warn)
    function automatic int hex_words(input string fn);
        int fd, n, c; reg [8*80-1:0] line;
        n = 0;
        fd = $fopen(fn, "r");
        if (fd == 0) return 0;
        c = $fgets(line, fd);
        while (c > 0) begin
            if (c > 1) n++;
            c = $fgets(line, fd);
        end
        $fclose(fd);
        return n;
    endfunction
    initial begin
        for (int i = 0; i < 64; i++) begin
            rom[i]  = 32'h0000_0013;
            sram[i] = 32'h0;
        end
        for (int i = 0; i < MEM_WORDS; i++) mem[i] = 32'h0;
        rom_file = ROM_FILE;
        mem_file = MEM_FILE;
        void'($value$plusargs("ROM_HEX=%s", rom_file));
        void'($value$plusargs("MEM_HEX=%s", mem_file));
        if (mem_file != "") begin
            n_mem = hex_words(mem_file);
            if (n_mem == 0 || n_mem > MEM_WORDS)
                $display("soc_core_top: ERROR main RAM image %s has %0d words", mem_file, n_mem);
            else
                $readmemh(mem_file, mem, 0, n_mem - 1);
            if (rom_file == "") begin                 // boot stub -> MEM_BASE
                rom[0] = {MEM_BASE[31:12], 5'd5, 7'b0110111};   // lui  t0, MEM_BASE>>12
                rom[1] = 32'h0002_8067;                         // jalr x0, 0(t0)
            end
        end
        if (rom_file != "") $readmemh(rom_file, rom);
    end

    always @(*) begin
        if (imem_addr < ROM_BASE + ROM_SIZE)
            imem_rdata = rom[imem_addr[7:2]];
        else if (imem_addr >= MEM_BASE && imem_addr < MEM_BASE + MEM_SIZE)
            imem_rdata = mem[imem_addr[15:2]];
        else
            imem_rdata = 32'h0000_0013;
    end

    logic rom_sel, sram_sel, uart_sel, gpio_sel, done_sel, timer_sel, irq_sel;
    logic uartb_sel, mem_sel, unmapped;
    addr_decode u_dec (
        .addr(dmem_addr),
        .rom_sel, .sram_sel, .uart_sel, .gpio_sel, .done_sel,
        .timer_sel, .irq_sel, .uartb_sel, .mem_sel, .unmapped
    );

    // UART: block at 0x230; legacy 0x200 writes alias to DATA (offset 0)
    logic [31:0] uart_rdata;
    uart #(.DIV_RESET(UART_DIV)) u_uart (
        .clk, .rst_n,
        .sel(uartb_sel || uart_sel), .we(dmem_we), .re(dmem_re && uartb_sel),
        .addr(uart_sel ? 4'h0 : dmem_addr[3:0]),
        .wdata(dmem_wdata), .rdata(uart_rdata),
        .tx(uart_tx), .rx(uart_rx),
        .tx_push(uart_valid), .tx_push_byte(uart_byte)
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
        else if (uartb_sel) dmem_rdata = uart_rdata;
        else if (mem_sel)   dmem_rdata = mem[dmem_addr[15:2]];
        else                dmem_rdata = 32'h0;   // UART TX alias and unmapped
    end

    logic err_now;
    assign err_now = (unmapped && (dmem_we || dmem_re)) || (rom_sel && dmem_we);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            gpio_out <= 8'd0; done <= 1'b0;
            bus_err <= 1'b0; bus_err_addr <= 32'd0;
        end else begin
            if (dmem_we && gpio_sel) gpio_out  <= dmem_wdata[7:0];
            if (dmem_we && done_sel) done      <= 1'b1;
            if (dmem_we && sram_sel)
                for (int b = 0; b < 4; b++)
                    if (dmem_wstrb[b]) sram[dmem_addr[7:2]][8*b +: 8] <= dmem_wdata[8*b +: 8];
            if (dmem_we && mem_sel)
                for (int b = 0; b < 4; b++)
                    if (dmem_wstrb[b]) mem[dmem_addr[15:2]][8*b +: 8] <= dmem_wdata[8*b +: 8];
            if (err_now && !bus_err) begin
                bus_err <= 1'b1; bus_err_addr <= dmem_addr;
            end
        end
    end
endmodule
