// timer.sv — Simple memory-mapped timer (one compare, one irq).
//   0x0 COUNT   RO     free-running counter (counts while CTRL.en = 1)
//   0x4 COMPARE RW     when COUNT == COMPARE the match flag is set
//   0x8 CTRL    RW     bit0 = count enable (reset 1, like soc_timer.sv)
//   0xC STATUS  R/W1C  bit0 = match flag; write 1 to clear
// irq = match flag (level, sticky until cleared by software).
import soc_map_pkg::*;

module timer (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        sel,
    input  logic        we,
    input  logic [3:0]  addr,      // byte offset within the timer block
    input  logic [31:0] wdata,
    output logic [31:0] rdata,
    output logic        irq
);
    logic [31:0] count, compare;
    logic        en, match;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            count   <= 32'd0;
            compare <= 32'hFFFF_FFFF;
            en      <= 1'b1;
            match   <= 1'b0;
        end else begin
            if (en) count <= count + 32'd1;
            // set has priority over a same-cycle W1C clear
            if (sel && we && addr == TIMER_STATUS && wdata[0]) match <= 1'b0;
            if (en && count == compare) match <= 1'b1;
            if (sel && we && addr == TIMER_COMPARE) compare <= wdata;
            if (sel && we && addr == TIMER_CTRL)    en      <= wdata[0];
        end
    end

    always @(*) begin
        case (addr)
            TIMER_COUNT:   rdata = count;
            TIMER_COMPARE: rdata = compare;
            TIMER_CTRL:    rdata = {31'd0, en};
            TIMER_STATUS:  rdata = {31'd0, match};
            default:       rdata = 32'd0;
        endcase
    end

    assign irq = match;
endmodule
