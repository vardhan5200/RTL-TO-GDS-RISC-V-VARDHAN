// irq_ctrl.sv — Simple memory-mapped interrupt controller.
//   0x0 PENDING RO   bit i = source i has been seen high (latched)
//   0x4 ENABLE  RW   bit i = source i may drive irq (reset 0)
//   0x8 ACK     W1C  write 1 to bit i to clear PENDING[i]; reads 0
//   0xC CLAIM   RO   bit31 = an enabled source is pending,
//                    [7:0] = id of lowest-numbered pending & enabled source
// irq = |(PENDING & ENABLE). Sources are level: if a source is still high
// when ACKed it re-pends next cycle, so clear the peripheral first, then ACK.
// Source 0 = timer.
import soc_map_pkg::*;

module irq_ctrl #(
    parameter int N = 8
) (
    input  logic         clk,
    input  logic         rst_n,
    input  logic         sel,
    input  logic         we,
    input  logic [3:0]   addr,     // byte offset within the irq block
    input  logic [31:0]  wdata,
    output logic [31:0]  rdata,
    input  logic [N-1:0] src,
    output logic         irq
);
    logic [N-1:0] pending, enable, active;
    assign active = pending & enable;
    assign irq    = |active;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pending <= '0;
            enable  <= '0;
        end else begin
            // new source assertion wins over a same-cycle ACK
            if (sel && we && addr == IRQ_ACK)
                pending <= (pending & ~wdata[N-1:0]) | src;
            else
                pending <= pending | src;
            if (sel && we && addr == IRQ_ENABLE)
                enable <= wdata[N-1:0];
        end
    end

    logic [7:0] claim_id;
    always @(*) begin
        claim_id = 8'd0;
        for (int i = N-1; i >= 0; i--)
            if (active[i]) claim_id = i[7:0];
    end

    always @(*) begin
        case (addr)
            IRQ_PENDING: rdata = 32'(pending);
            IRQ_ENABLE:  rdata = 32'(enable);
            IRQ_CLAIM:   rdata = {irq, 23'd0, claim_id};
            default:     rdata = 32'd0;
        endcase
    end
endmodule
