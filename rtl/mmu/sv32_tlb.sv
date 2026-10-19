// sv32_tlb.sv — small fully-associative TLB for Sv32
// - Combinational lookup on lookup_vpn.
// - One refill port, round-robin replacement.
// - flush clears every entry (sfence.vma with rs1=rs2=x0 semantics).
// - No ASID support; G bit is stored but not used.
//
// perm = PTE[7:0] = {D, A, G, U, X, W, R, V}

module sv32_tlb #(
    parameter int ENTRIES = 4
) (
    input  logic        clk,
    input  logic        rst_n,

    // lookup (combinational)
    input  logic [19:0] lookup_vpn,       // vaddr[31:12]
    output logic        lookup_hit,
    output logic [21:0] lookup_ppn,
    output logic [7:0]  lookup_perm,
    output logic        lookup_mega,      // 1 = 4 MiB megapage

    // refill
    input  logic        refill_valid,
    input  logic [19:0] refill_vpn,
    input  logic [21:0] refill_ppn,
    input  logic [7:0]  refill_perm,
    input  logic        refill_mega,

    // flush all
    input  logic        flush
);
    localparam int IW = (ENTRIES > 1) ? $clog2(ENTRIES) : 1;

    logic        valid [0:ENTRIES-1];
    logic [19:0] vpn   [0:ENTRIES-1];
    logic [21:0] ppn   [0:ENTRIES-1];
    logic [7:0]  perm  [0:ENTRIES-1];
    logic        mega  [0:ENTRIES-1];
    logic [IW-1:0] rr_ptr;

    // per-entry match: megapages compare VPN[1] only
    logic [ENTRIES-1:0] match;
    genvar g;
    generate
        for (g = 0; g < ENTRIES; g++) begin : g_match
            assign match[g] = valid[g] &&
                              (vpn[g][19:10] == lookup_vpn[19:10]) &&
                              (mega[g] || (vpn[g][9:0] == lookup_vpn[9:0]));
        end
    endgenerate

    // first matching entry wins (refill never creates duplicates for a VPN
    // because the MMU only refills after a miss)
    always_comb begin
        lookup_hit  = 1'b0;
        lookup_ppn  = 22'b0;
        lookup_perm = 8'b0;
        lookup_mega = 1'b0;
        for (int i = 0; i < ENTRIES; i++) begin
            if (!lookup_hit && match[i]) begin
                lookup_hit  = 1'b1;
                lookup_ppn  = ppn[i];
                lookup_perm = perm[i];
                lookup_mega = mega[i];
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rr_ptr <= '0;
            for (int i = 0; i < ENTRIES; i++) valid[i] <= 1'b0;
        end else if (flush) begin
            rr_ptr <= '0;
            for (int i = 0; i < ENTRIES; i++) valid[i] <= 1'b0;
        end else if (refill_valid) begin
            valid[rr_ptr] <= 1'b1;
            vpn[rr_ptr]   <= refill_vpn;
            ppn[rr_ptr]   <= refill_ppn;
            perm[rr_ptr]  <= refill_perm;
            mega[rr_ptr]  <= refill_mega;
            rr_ptr <= (rr_ptr == IW'(ENTRIES-1)) ? '0 : rr_ptr + 1'b1;
        end
    end
endmodule
