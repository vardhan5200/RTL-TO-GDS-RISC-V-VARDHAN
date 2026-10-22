// demo_soc.sv — simulation "FPGA demo" SoC: the integrated pipelined core
// (rtl/core/core_top.sv, same configuration as soc_core_top) + Boot ROM stub
// + 64 KiB main RAM + UART (rtl/soc/uart.sv) + 7-segment display
// (rtl/peripherals/seven_seg.sv) + 4x4 matrix multiply accelerator
// (rtl/peripherals/matmul4x4.sv) + GPIO/DONE.
//
// Address map: every soc_map_pkg region keeps its address (decoded by the
// shared addr_decode); demo-only regions are decoded here:
//   0x0000_0240 - 0x0000_024F  7-segment   (SEG_BASE)
//   0x0000_0400 - 0x0000_04FF  matmul4x4   (MATMUL_BASE)
// Timer / irq controller are not instantiated (the demo is polled); their
// addresses read 0 and set bus_err like any unmapped access.
// Program loading is the same as soc_core_top: MEM_FILE / +MEM_HEX=<file>
// into main RAM (0x0001_0000) and a 2-word Boot ROM stub at the reset vector
// (0x0: lui t0,0x10 ; 0x4: jalr x0,0(t0)).
import soc_map_pkg::*;

module demo_soc #(
    parameter string MEM_FILE = "",
    parameter int    UART_DIV = 16
) (
    input  logic        clk,
    input  logic        rst_n,
    output logic        uart_tx,
    input  logic        uart_rx,
    output logic [7:0]  uart_byte,     // sim tap: byte accepted into TX FIFO
    output logic        uart_valid,
    output logic [6:0]  seg,           // {g,f,e,d,c,b,a}, active high
    output logic        seg_dp,
    output logic [3:0]  seg_digit,
    output logic        seg_wr,        // pulses after each 7-seg write
    output logic [7:0]  gpio_out,
    output logic        done,
    output logic        bus_err,
    output logic [31:0] bus_err_addr
);
    logic [31:0] imem_addr, imem_rdata;
    logic        dmem_we, dmem_re, mmu_fault;
    logic [31:0] dmem_addr, dmem_wdata, dmem_rdata;
    logic [3:0]  dmem_wstrb;

    core_top #(.CACHE_BASE(ROM_BASE), .CACHE_LIMIT(SRAM_BASE + SRAM_SIZE)) core (
        .clk, .rst_n,
        .imem_addr, .imem_rdata,
        .dmem_re, .dmem_we, .dmem_addr, .dmem_wdata, .dmem_wstrb, .dmem_rdata,
        .meip(1'b0), .mtip(1'b0), .msip(1'b0),
        .mmu_fault
    );

    // ---------------- memories + program load ----------------
    logic [31:0] rom  [0:63];
    logic [31:0] sram [0:63];
    logic [31:0] mem  [0:MEM_WORDS-1];
    string mem_file;
    int    n_mem;
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
        for (int i = 0; i < 64; i++) begin rom[i] = 32'h0000_0013; sram[i] = 32'h0; end
        for (int i = 0; i < MEM_WORDS; i++) mem[i] = 32'h0;
        rom[0] = {MEM_BASE[31:12], 5'd5, 7'b0110111};   // lui  t0, MEM_BASE>>12
        rom[1] = 32'h0002_8067;                         // jalr x0, 0(t0)
        mem_file = MEM_FILE;
        void'($value$plusargs("MEM_HEX=%s", mem_file));
        n_mem = (mem_file != "") ? hex_words(mem_file) : 0;
        if (n_mem == 0 || n_mem > MEM_WORDS)
            $display("demo_soc: ERROR main RAM image '%s' has %0d words", mem_file, n_mem);
        else
            $readmemh(mem_file, mem, 0, n_mem - 1);
    end

    always @(*) begin
        if (imem_addr < ROM_BASE + ROM_SIZE)
            imem_rdata = rom[imem_addr[7:2]];
        else if (imem_addr >= MEM_BASE && imem_addr < MEM_BASE + MEM_SIZE)
            imem_rdata = mem[imem_addr[15:2]];
        else
            imem_rdata = 32'h0000_0013;
    end

    // ---------------- decode ----------------
    logic rom_sel, sram_sel, uart_sel, gpio_sel, done_sel, timer_sel, irq_sel;
    logic uartb_sel, mem_sel, dec_unmapped, seg_sel, mm_sel, unmapped;
    addr_decode u_dec (
        .addr(dmem_addr),
        .rom_sel, .sram_sel, .uart_sel, .gpio_sel, .done_sel,
        .timer_sel, .irq_sel, .uartb_sel, .mem_sel, .unmapped(dec_unmapped)
    );
    assign seg_sel  = (dmem_addr >= SEG_BASE)    && (dmem_addr < SEG_BASE + SEG_SIZE);
    assign mm_sel   = (dmem_addr >= MATMUL_BASE) && (dmem_addr < MATMUL_BASE + MATMUL_SIZE);
    // timer / irq controller are not present in the demo -> unmapped
    assign unmapped = (dec_unmapped && !seg_sel && !mm_sel) || timer_sel || irq_sel;

    // ---------------- peripherals ----------------
    logic [31:0] uart_rdata, seg_rdata, mm_rdata;
    logic        mm_done;

    uart #(.DIV_RESET(UART_DIV)) u_uart (
        .clk, .rst_n,
        .sel(uartb_sel || uart_sel), .we(dmem_we), .re(dmem_re && uartb_sel),
        .addr(uart_sel ? 4'h0 : dmem_addr[3:0]),
        .wdata(dmem_wdata), .rdata(uart_rdata),
        .tx(uart_tx), .rx(uart_rx),
        .tx_push(uart_valid), .tx_push_byte(uart_byte)
    );

    seven_seg u_seg (
        .clk, .rst_n,
        .sel(seg_sel), .we(dmem_we), .wstrb(dmem_wstrb), .addr(dmem_addr[3:0]),
        .wdata(dmem_wdata), .rdata(seg_rdata),
        .seg, .dp(seg_dp), .digit(seg_digit), .wr_pulse(seg_wr)
    );

    matmul4x4 u_mm (
        .clk, .rst_n,
        .sel(mm_sel), .we(dmem_we), .addr(dmem_addr[7:0]),
        .wdata(dmem_wdata), .rdata(mm_rdata), .done_o(mm_done)
    );

    always @(*) begin
        if      (rom_sel)   dmem_rdata = rom[dmem_addr[7:2]];
        else if (sram_sel)  dmem_rdata = sram[dmem_addr[7:2]];
        else if (gpio_sel)  dmem_rdata = {24'd0, gpio_out};
        else if (done_sel)  dmem_rdata = {31'd0, done};
        else if (uartb_sel) dmem_rdata = uart_rdata;
        else if (seg_sel)   dmem_rdata = seg_rdata;
        else if (mm_sel)    dmem_rdata = mm_rdata;
        else if (mem_sel)   dmem_rdata = mem[dmem_addr[15:2]];
        else                dmem_rdata = 32'h0;
    end

    logic err_now;
    assign err_now = (unmapped && (dmem_we || dmem_re)) || (rom_sel && dmem_we);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            gpio_out <= 8'd0; done <= 1'b0; bus_err <= 1'b0; bus_err_addr <= 32'd0;
        end else begin
            if (dmem_we && gpio_sel) gpio_out <= dmem_wdata[7:0];
            if (dmem_we && done_sel) done     <= 1'b1;
            if (dmem_we && sram_sel)
                for (int b = 0; b < 4; b++)
                    if (dmem_wstrb[b]) sram[dmem_addr[7:2]][8*b +: 8] <= dmem_wdata[8*b +: 8];
            if (dmem_we && mem_sel)
                for (int b = 0; b < 4; b++)
                    if (dmem_wstrb[b]) mem[dmem_addr[15:2]][8*b +: 8] <= dmem_wdata[8*b +: 8];
            if (err_now && !bus_err) begin bus_err <= 1'b1; bus_err_addr <= dmem_addr; end
        end
    end
endmodule
