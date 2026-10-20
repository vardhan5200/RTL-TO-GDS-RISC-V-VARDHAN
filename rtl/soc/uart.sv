// uart.sv — Memory-mapped 8N1 UART with TX/RX FIFOs and a programmable
// baud divider (clocks per bit). Register block (byte offsets):
//   0x0 DATA     W  push byte [7:0] into the TX FIFO (dropped + TX_OVERFLOW
//                   set if the FIFO is full — poll STATUS.TX_READY first)
//                R  pop the RX FIFO: {23'b0, valid[8], byte[7:0]}; valid=0
//                   and byte=0 when empty (a read pops only when valid)
//   0x4 STATUS   R  bit0 TX_READY  TX FIFO not full (safe to write DATA)
//                   bit1 TX_IDLE   TX FIFO empty and shifter idle
//                   bit2 RX_VALID  RX FIFO not empty
//                   bit3 RX_OVERRUN sticky: byte received while RX FIFO full
//                   bit4 TX_OVERFLOW sticky: DATA written while TX FIFO full
//                W  write 1 to bit3 / bit4 to clear the sticky flags
//   0x8 BAUDDIV  RW clocks per bit (reset DIV_RESET; values < 4 read back as 4)
// Serial frame: start(0), 8 data bits LSB first, stop(1); line idles high.
// RX samples mid-bit after a 2-flop synchronizer; frames whose stop bit is 0
// are discarded. `re` must be a single-cycle strobe per load (the core issues
// exactly one dmem_re cycle per uncached load).
import soc_map_pkg::*;

module uart #(
    parameter int DIV_RESET = 16,
    parameter int DEPTH     = 16          // FIFO depth (power of two)
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        sel,
    input  logic        we,
    input  logic        re,
    input  logic [3:0]  addr,
    input  logic [31:0] wdata,
    output logic [31:0] rdata,
    output logic        tx,              // serial out
    input  logic        rx,              // serial in
    output logic        tx_push,         // sim tap: byte accepted into TX FIFO
    output logic [7:0]  tx_push_byte
);
    localparam int AW = $clog2(DEPTH);

    // ---------------- baud divider ----------------
    logic [15:0] div;
    wire  [15:0] div_eff = (div < 16'd4) ? 16'd4 : div;

    // ---------------- TX FIFO ----------------
    logic [7:0]  txq [0:DEPTH-1];
    logic [AW:0] tx_cnt;
    logic [AW-1:0] tx_wp, tx_rp;
    wire tx_full  = (tx_cnt == DEPTH);
    wire tx_empty = (tx_cnt == 0);

    // ---------------- RX FIFO ----------------
    logic [7:0]  rxq [0:DEPTH-1];
    logic [AW:0] rx_cnt;
    logic [AW-1:0] rx_wp, rx_rp;
    wire rx_full  = (rx_cnt == DEPTH);
    wire rx_empty = (rx_cnt == 0);

    logic rx_ovr, tx_ovf;

    // bus strobes
    wire wr_data = sel && we && addr == UART_DATA;
    wire rd_data = sel && re && addr == UART_DATA;
    assign tx_push      = wr_data && !tx_full;
    assign tx_push_byte = wdata[7:0];
    wire rx_pop  = rd_data && !rx_empty;

    // ---------------- TX shifter ----------------
    logic        tx_busy;
    logic [9:0]  tx_sh;
    logic [3:0]  tx_bits;
    logic [15:0] tx_tick;
    wire tx_pop = !tx_busy && !tx_empty;

    // ---------------- RX sampler ----------------
    logic rx_s1, rx_s2;
    logic        rx_busy;
    logic [3:0]  rx_bits;     // 0 = start bit, 1..8 data, 9 stop
    logic [15:0] rx_tick;
    logic [7:0]  rx_sh;
    logic        rx_push;
    logic [7:0]  rx_push_byte;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            div <= 16'(DIV_RESET);
            tx_cnt <= '0; tx_wp <= '0; tx_rp <= '0;
            rx_cnt <= '0; rx_wp <= '0; rx_rp <= '0;
            rx_ovr <= 1'b0; tx_ovf <= 1'b0;
            tx_busy <= 1'b0; tx_sh <= 10'h3FF; tx_bits <= '0; tx_tick <= '0; tx <= 1'b1;
            rx_s1 <= 1'b1; rx_s2 <= 1'b1;
            rx_busy <= 1'b0; rx_bits <= '0; rx_tick <= '0; rx_sh <= '0;
            rx_push <= 1'b0; rx_push_byte <= '0;
        end else begin
            // ---- registers ----
            if (sel && we && addr == UART_BAUDDIV) div <= wdata[15:0];
            if (sel && we && addr == UART_STATUS) begin
                if (wdata[3]) rx_ovr <= 1'b0;
                if (wdata[4]) tx_ovf <= 1'b0;
            end
            if (wr_data && tx_full) tx_ovf <= 1'b1;

            // ---- TX FIFO ----
            if (tx_push) begin txq[tx_wp] <= wdata[7:0]; tx_wp <= tx_wp + 1'b1; end
            if (tx_pop)  tx_rp <= tx_rp + 1'b1;
            tx_cnt <= tx_cnt + (tx_push ? 1'b1 : 1'b0) - (tx_pop ? 1'b1 : 1'b0);

            // ---- TX shifter ----
            if (tx_pop) begin
                tx_busy <= 1'b1;
                tx_sh   <= {1'b1, txq[tx_rp], 1'b0};   // stop, data, start
                tx_bits <= 4'd0;
                tx_tick <= '0;
                tx      <= 1'b0;                       // start bit now
            end else if (tx_busy) begin
                if (tx_tick == div_eff - 1) begin
                    tx_tick <= '0;
                    if (tx_bits == 4'd9) begin
                        tx_busy <= 1'b0; tx <= 1'b1;
                    end else begin
                        tx_bits <= tx_bits + 1'b1;
                        tx      <= tx_sh[tx_bits + 1];
                    end
                end else
                    tx_tick <= tx_tick + 1'b1;
            end

            // ---- RX sampler ----
            rx_s1 <= rx; rx_s2 <= rx_s1;
            rx_push <= 1'b0;
            if (!rx_busy) begin
                if (!rx_s2) begin                       // start bit edge
                    rx_busy <= 1'b1; rx_bits <= 4'd0; rx_tick <= '0;
                end
            end else begin
                // sample point: middle of start bit, then every div_eff clocks
                if (rx_tick == ((rx_bits == 0) ? (div_eff >> 1) - 1 : div_eff - 1)) begin
                    rx_tick <= '0;
                    if (rx_bits == 4'd0) begin
                        if (rx_s2) rx_busy <= 1'b0;     // glitch, not a start bit
                        else rx_bits <= 4'd1;
                    end else if (rx_bits <= 4'd8) begin
                        rx_sh   <= {rx_s2, rx_sh[7:1]};
                        rx_bits <= rx_bits + 1'b1;
                    end else begin                      // stop bit
                        rx_busy <= 1'b0;
                        if (rx_s2) begin rx_push <= 1'b1; rx_push_byte <= rx_sh; end
                    end
                end else
                    rx_tick <= rx_tick + 1'b1;
            end

            // ---- RX FIFO ----
            if (rx_push && !rx_full) begin rxq[rx_wp] <= rx_push_byte; rx_wp <= rx_wp + 1'b1; end
            if (rx_push && rx_full)  rx_ovr <= 1'b1;
            if (rx_pop) rx_rp <= rx_rp + 1'b1;
            rx_cnt <= rx_cnt + ((rx_push && !rx_full) ? 1'b1 : 1'b0) - (rx_pop ? 1'b1 : 1'b0);
        end
    end

    always @(*) begin
        case (addr)
            UART_DATA:    rdata = rx_empty ? 32'd0 : {23'd0, 1'b1, rxq[rx_rp]};
            UART_STATUS:  rdata = {27'd0, tx_ovf, rx_ovr, !rx_empty,
                                   (tx_empty && !tx_busy), !tx_full};
            UART_BAUDDIV: rdata = {16'd0, div_eff};
            default:      rdata = 32'd0;
        endcase
    end
endmodule
