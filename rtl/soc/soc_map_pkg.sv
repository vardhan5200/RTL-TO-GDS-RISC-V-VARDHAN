// soc_map_pkg.sv — Single source of truth for the as-built SoC memory map.
// All addresses are byte addresses; every region is word (32-bit) accessed.
// Everything sits in the low 4 KiB so programs can reach it with x0+imm12
// (e.g. `sw x1, 0x200(x0)`), matching the existing soc.sv programs.
//
//   0x0000_0000 - 0x0000_00FF  Boot ROM      (64 words, read-only)
//   0x0000_0100 - 0x0000_01FF  SRAM          (64 words, read/write)
//   0x0000_0200                UART TX alias (write-only byte -> UART DATA)
//   0x0000_0204                GPIO OUT      (read/write byte)
//   0x0000_0208                DONE flag     (write any value -> done=1)
//   0x0000_0210 - 0x0000_021F  Timer         (4 registers)
//   0x0000_0220 - 0x0000_022F  IRQ controller (4 registers)
//   0x0000_0230 - 0x0000_023F  UART          (DATA, STATUS, BAUDDIV)
//   0x0000_0240 - 0x0000_024F  7-segment     (demo_soc only)
//   0x0000_0400 - 0x0000_04FF  matmul4x4     (demo_soc only)
//   0x0001_0000 - 0x0001_FFFF  Main RAM      (64 KiB code+data+stack,
//                                             preloadable program image)
//   everything else            unmapped -> read 0, bus_err flagged

package soc_map_pkg;
    // Region bases / sizes
    localparam logic [31:0] ROM_BASE   = 32'h0000_0000;
    localparam logic [31:0] ROM_SIZE   = 32'h0000_0100;
    localparam logic [31:0] SRAM_BASE  = 32'h0000_0100;
    localparam logic [31:0] SRAM_SIZE  = 32'h0000_0100;
    localparam logic [31:0] UART_ADDR  = 32'h0000_0200;
    localparam logic [31:0] GPIO_ADDR  = 32'h0000_0204;
    localparam logic [31:0] DONE_ADDR  = 32'h0000_0208;
    localparam logic [31:0] TIMER_BASE = 32'h0000_0210;
    localparam logic [31:0] TIMER_SIZE = 32'h0000_0010;
    localparam logic [31:0] IRQ_BASE   = 32'h0000_0220;
    localparam logic [31:0] IRQ_SIZE   = 32'h0000_0010;
    localparam logic [31:0] UART_BASE  = 32'h0000_0230;
    localparam logic [31:0] UART_SIZE  = 32'h0000_0010;
    // demo_soc-only peripherals (rtl/peripherals/); addr_decode, soc_top and
    // soc_core_top do not decode them (they stay unmapped there).
    localparam logic [31:0] SEG_BASE    = 32'h0000_0240;
    localparam logic [31:0] SEG_SIZE    = 32'h0000_0010;
    localparam logic [31:0] MATMUL_BASE = 32'h0000_0400;
    localparam logic [31:0] MATMUL_SIZE = 32'h0000_0100;
    localparam logic [31:0] MEM_BASE   = 32'h0001_0000;
    localparam logic [31:0] MEM_SIZE   = 32'h0001_0000;  // 64 KiB
    localparam int          MEM_WORDS  = 16384;
    localparam logic [31:0] RESET_VECTOR = 32'h0000_0000;  // core_top PC reset

    // Timer register offsets
    localparam logic [3:0] TIMER_COUNT   = 4'h0; // RO  free-running counter
    localparam logic [3:0] TIMER_COMPARE = 4'h4; // RW  match value
    localparam logic [3:0] TIMER_CTRL    = 4'h8; // RW  bit0 = count enable
    localparam logic [3:0] TIMER_STATUS  = 4'hC; // R/W1C bit0 = match flag (irq src 0)

    // IRQ controller register offsets
    localparam logic [3:0] IRQ_PENDING = 4'h0;   // RO  latched pending bits
    localparam logic [3:0] IRQ_ENABLE  = 4'h4;   // RW  per-source enable
    localparam logic [3:0] IRQ_ACK     = 4'h8;   // W1C clear pending bits (reads 0)
    localparam logic [3:0] IRQ_CLAIM   = 4'hC;   // RO  {valid, ..., id}

    // UART register offsets
    localparam logic [3:0] UART_DATA    = 4'h0;  // W: push TX FIFO; R: pop RX FIFO {valid[8], byte[7:0]}
    localparam logic [3:0] UART_STATUS  = 4'h4;  // R: bit0 TX_READY, 1 TX_IDLE, 2 RX_VALID,
                                                 //    3 RX_OVERRUN, 4 TX_OVERFLOW; W1C bits 3/4
    localparam logic [3:0] UART_BAUDDIV = 4'h8;  // RW clocks per bit (>= 4)

    // IRQ source numbers
    localparam int IRQ_SRC_TIMER = 0;
endpackage
