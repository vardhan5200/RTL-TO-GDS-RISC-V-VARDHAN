// sv32_ptw.sv — two-level Sv32 page-table walker
//
// Root table = satp.PPN * 4096. One 32-bit PTE read per level over a
// read-only ready/valid memory port (same handshake as docs/interfaces.md,
// but 32-bit data and a 34-bit Sv32 physical address).
//
// PTE layout: [31:20] PPN[1]  [19:10] PPN[0]  [9:8] RSW
//             [7] D [6] A [5] G [4] U [3] X [2] W [1] R [0] V
//
// Faults (done && page_fault):
//   - V=0, or R=0 & W=1 (reserved encoding)
//   - pointer PTE at level 0 (no leaf found)
//   - misaligned superpage (level-1 leaf with PPN[0] != 0)
//   - leaf permission / A / D check fails (see sv32_perm_check)
// mem_resp_error -> done && access_fault.
// A/D bits are never updated by hardware.

module sv32_ptw (
    input  logic        clk,
    input  logic        rst_n,

    // walk request (start is a 1-cycle pulse, only accepted when !busy)
    input  logic        start,
    input  logic [21:0] satp_ppn,
    input  logic [19:0] vpn,          // vaddr[31:12]
    input  logic [1:0]  acc,          // 0 load, 1 store, 2 fetch
    input  logic [1:0]  priv,         // 00 U, 01 S
    input  logic        sum,
    input  logic        mxr,
    output logic        busy,

    // walk result (done is a 1-cycle pulse)
    output logic        done,
    output logic        page_fault,
    output logic        access_fault,
    output logic [21:0] leaf_ppn,
    output logic [7:0]  leaf_perm,
    output logic        leaf_mega,

    // memory read port
    output logic        mem_req_valid,
    input  logic        mem_req_ready,
    output logic [33:0] mem_req_addr,
    input  logic        mem_resp_valid,
    output logic        mem_resp_ready,
    input  logic [31:0] mem_resp_rdata,
    input  logic        mem_resp_error
);
    localparam logic [1:0] S_IDLE = 2'd0,
                           S_REQ  = 2'd1,
                           S_WAIT = 2'd2;

    logic [1:0]  state;
    logic        level;           // 1 = root level, 0 = leaf level
    logic [33:0] pte_addr;
    logic [19:0] vpn_q;
    logic [1:0]  acc_q, priv_q;
    logic        sum_q, mxr_q;

    // decode of the returned PTE
    logic [31:0] pte;
    logic        pte_v, pte_r, pte_w, pte_x, pte_leaf, pte_bad, perm_ok;

    assign pte      = mem_resp_rdata;
    assign pte_v    = pte[0];
    assign pte_r    = pte[1];
    assign pte_w    = pte[2];
    assign pte_x    = pte[3];
    assign pte_leaf = pte_r | pte_x;
    assign pte_bad  = !pte_v || (!pte_r && pte_w);

    sv32_perm_check u_perm (
        .perm (pte[7:0]),
        .acc  (acc_q),
        .priv (priv_q),
        .sum  (sum_q),
        .mxr  (mxr_q),
        .ok   (perm_ok)
    );

    assign busy           = (state != S_IDLE);
    assign mem_req_valid  = (state == S_REQ);
    assign mem_req_addr   = pte_addr;
    assign mem_resp_ready = (state == S_WAIT);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= S_IDLE;
            level        <= 1'b1;
            pte_addr     <= '0;
            vpn_q        <= '0;
            acc_q        <= '0;
            priv_q       <= '0;
            sum_q        <= 1'b0;
            mxr_q        <= 1'b0;
            done         <= 1'b0;
            page_fault   <= 1'b0;
            access_fault <= 1'b0;
            leaf_ppn     <= '0;
            leaf_perm    <= '0;
            leaf_mega    <= 1'b0;
        end else begin
            done <= 1'b0;
            case (state)
                S_IDLE: if (start) begin
                    vpn_q    <= vpn;
                    acc_q    <= acc;
                    priv_q   <= priv;
                    sum_q    <= sum;
                    mxr_q    <= mxr;
                    level    <= 1'b1;
                    pte_addr <= {satp_ppn, 12'b0} + {22'b0, vpn[19:10], 2'b00};
                    state    <= S_REQ;
                end

                S_REQ: if (mem_req_ready) state <= S_WAIT;

                S_WAIT: if (mem_resp_valid) begin
                    page_fault   <= 1'b0;
                    access_fault <= 1'b0;
                    leaf_ppn     <= pte[31:10];
                    leaf_perm    <= pte[7:0];
                    leaf_mega    <= level;
                    if (mem_resp_error) begin
                        access_fault <= 1'b1;
                        done  <= 1'b1;
                        state <= S_IDLE;
                    end else if (pte_bad) begin
                        page_fault <= 1'b1;
                        done  <= 1'b1;
                        state <= S_IDLE;
                    end else if (!pte_leaf) begin
                        if (level) begin
                            // pointer to next level
                            level    <= 1'b0;
                            pte_addr <= {pte[31:10], 12'b0} + {22'b0, vpn_q[9:0], 2'b00};
                            state    <= S_REQ;
                        end else begin
                            page_fault <= 1'b1;     // no leaf at level 0
                            done  <= 1'b1;
                            state <= S_IDLE;
                        end
                    end else begin
                        // leaf
                        if ((level && pte[19:10] != 10'b0) || !perm_ok)
                            page_fault <= 1'b1;     // misaligned superpage / perms
                        done  <= 1'b1;
                        state <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
