// sv32_mmu.sv — Sv32 MMU skeleton: TLB + page-table walker
//
// One translation at a time (blocking, like the L1 caches).
//   req  : req_valid / req_ready / req_vaddr / req_acc
//   resp : resp_valid / resp_ready / resp_paddr / resp_page_fault / ...
// The response is registered (>= 1 cycle after acceptance) and held until
// resp_ready.
//
// Bare (passthrough, paddr = {2'b0, vaddr}, no fault) when satp.MODE = 0
// or priv = M. MPRV is not modelled.
// TLB hit  : permission check on the cached PTE bits, respond next cycle.
// TLB miss : walk with sv32_ptw, refill the TLB on a successful walk only
//            (faulting walks are not cached), then respond.
// flush    : sfence.vma style flush-all. A walk in flight while flush is
//            seen completes but does not refill the TLB.
//
// resp_cause (0 when no fault), RISC-V mcause encoding:
//   fetch : 12 page fault / 1 access fault
//   load  : 13 page fault / 5 access fault
//   store : 15 page fault / 7 access fault
//
// Limitations (skeleton): no ASID / G matching, flush-all only, no hardware
// A/D update (A=0 or store with D=0 -> page fault), no PMP/PMA checks, no
// MPRV, one outstanding translation, faulting walks are not cached, 34-bit
// PA is produced but the SoC only decodes 32 bits.
//
// Integration points (not wired into the pipeline yet):
//   - IF : translate the fetch PC (req_acc=2) before the I-cache request;
//          stall IF while !resp_valid; page fault -> cause 12.
//   - MEM: translate load/store address (req_acc=0/1) before the D-cache;
//          stall MEM; page faults -> cause 13 / 15 into the trap logic.
//   - CSR: satp, priv, mstatus.SUM/MXR come from a future CSR file;
//          sfence.vma drives flush.
//   - mem_* port: route through the cache-to-memory arbiter (or the
//          D-cache) for PTE reads; needs an extra arbiter requester.
//   - Two instances (I-side and D-side) or one shared MMU with an arbiter.

module sv32_mmu #(
    parameter int TLB_ENTRIES = 4
) (
    input  logic        clk,
    input  logic        rst_n,

    // CSR / privilege state
    input  logic [31:0] satp,          // [31] MODE, [30:22] ASID (unused), [21:0] PPN
    input  logic [1:0]  priv,          // 00 U, 01 S, 11 M
    input  logic        sum,           // mstatus.SUM (tie 0 if unused)
    input  logic        mxr,           // mstatus.MXR (tie 0 if unused)
    input  logic        flush,         // sfence.vma (flush all)

    // translation request
    input  logic        req_valid,
    output logic        req_ready,
    input  logic [31:0] req_vaddr,
    input  logic [1:0]  req_acc,       // 0 load, 1 store, 2 fetch

    // translation response
    output logic        resp_valid,
    input  logic        resp_ready,
    output logic [33:0] resp_paddr,
    output logic        resp_page_fault,
    output logic        resp_access_fault,
    output logic [3:0]  resp_cause,

    // page-table memory read port (from the walker)
    output logic        mem_req_valid,
    input  logic        mem_req_ready,
    output logic [33:0] mem_req_addr,
    input  logic        mem_resp_valid,
    output logic        mem_resp_ready,
    input  logic [31:0] mem_resp_rdata,
    input  logic        mem_resp_error
);
    localparam logic [1:0] S_IDLE = 2'd0,
                           S_WALK = 2'd1,
                           S_RESP = 2'd2;

    localparam logic [1:0] ACC_LOAD = 2'd0, ACC_STORE = 2'd1, ACC_FETCH = 2'd2;

    logic [1:0]  state;
    logic [31:0] vaddr_q;
    logic [1:0]  acc_q;
    logic        flushed_q;

    logic        bare;
    assign bare = !satp[31] || (priv == 2'b11);

    // ---------------- TLB ----------------
    logic        tlb_hit, tlb_mega;
    logic [21:0] tlb_ppn;
    logic [7:0]  tlb_perm;
    logic        tlb_refill;
    logic        hit_ok;

    // ---------------- PTW ----------------
    logic        ptw_start, ptw_busy, ptw_done;
    logic        ptw_pf, ptw_af, ptw_mega;
    logic [21:0] ptw_ppn;
    logic [7:0]  ptw_perm;

    sv32_tlb #(.ENTRIES(TLB_ENTRIES)) u_tlb (
        .clk          (clk),
        .rst_n        (rst_n),
        .lookup_vpn   (req_vaddr[31:12]),
        .lookup_hit   (tlb_hit),
        .lookup_ppn   (tlb_ppn),
        .lookup_perm  (tlb_perm),
        .lookup_mega  (tlb_mega),
        .refill_valid (tlb_refill),
        .refill_vpn   (vaddr_q[31:12]),
        .refill_ppn   (ptw_ppn),
        .refill_perm  (ptw_perm),
        .refill_mega  (ptw_mega),
        .flush        (flush)
    );

    sv32_perm_check u_hit_perm (
        .perm (tlb_perm),
        .acc  (req_acc),
        .priv (priv),
        .sum  (sum),
        .mxr  (mxr),
        .ok   (hit_ok)
    );

    sv32_ptw u_ptw (
        .clk            (clk),
        .rst_n          (rst_n),
        .start          (ptw_start),
        .satp_ppn       (satp[21:0]),
        .vpn            (req_vaddr[31:12]),
        .acc            (req_acc),
        .priv           (priv),
        .sum            (sum),
        .mxr            (mxr),
        .busy           (ptw_busy),
        .done           (ptw_done),
        .page_fault     (ptw_pf),
        .access_fault   (ptw_af),
        .leaf_ppn       (ptw_ppn),
        .leaf_perm      (ptw_perm),
        .leaf_mega      (ptw_mega),
        .mem_req_valid  (mem_req_valid),
        .mem_req_ready  (mem_req_ready),
        .mem_req_addr   (mem_req_addr),
        .mem_resp_valid (mem_resp_valid),
        .mem_resp_ready (mem_resp_ready),
        .mem_resp_rdata (mem_resp_rdata),
        .mem_resp_error (mem_resp_error)
    );

    assign req_ready  = (state == S_IDLE) && !flush;
    assign resp_valid = (state == S_RESP);

    logic accept;
    assign accept     = req_valid && req_ready;
    assign ptw_start  = accept && !bare && !tlb_hit;
    assign tlb_refill = (state == S_WALK) && ptw_done && !ptw_pf && !ptw_af
                        && !flushed_q && !flush;

    function automatic logic [33:0] make_pa(input logic [21:0] ppn,
                                            input logic        mega,
                                            input logic [31:0] va);
        make_pa = mega ? {ppn[21:10], va[21:0]} : {ppn, va[11:0]};
    endfunction

    function automatic logic [3:0] cause_of(input logic [1:0] acc, input logic pf);
        case (acc)
            ACC_FETCH: cause_of = pf ? 4'd12 : 4'd1;
            ACC_STORE: cause_of = pf ? 4'd15 : 4'd7;
            default:   cause_of = pf ? 4'd13 : 4'd5;
        endcase
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state             <= S_IDLE;
            vaddr_q           <= '0;
            acc_q             <= '0;
            flushed_q         <= 1'b0;
            resp_paddr        <= '0;
            resp_page_fault   <= 1'b0;
            resp_access_fault <= 1'b0;
            resp_cause        <= '0;
        end else begin
            case (state)
                S_IDLE: if (accept) begin
                    vaddr_q   <= req_vaddr;
                    acc_q     <= req_acc;
                    flushed_q <= 1'b0;
                    if (bare) begin
                        resp_paddr        <= {2'b00, req_vaddr};
                        resp_page_fault   <= 1'b0;
                        resp_access_fault <= 1'b0;
                        resp_cause        <= '0;
                        state             <= S_RESP;
                    end else if (tlb_hit) begin
                        resp_paddr        <= make_pa(tlb_ppn, tlb_mega, req_vaddr);
                        resp_page_fault   <= !hit_ok;
                        resp_access_fault <= 1'b0;
                        resp_cause        <= hit_ok ? 4'd0 : cause_of(req_acc, 1'b1);
                        state             <= S_RESP;
                    end else begin
                        state <= S_WALK;
                    end
                end

                S_WALK: begin
                    if (flush) flushed_q <= 1'b1;
                    if (ptw_done) begin
                        resp_paddr        <= make_pa(ptw_ppn, ptw_mega, vaddr_q);
                        resp_page_fault   <= ptw_pf;
                        resp_access_fault <= ptw_af;
                        resp_cause        <= (ptw_pf || ptw_af) ? cause_of(acc_q, ptw_pf) : 4'd0;
                        state             <= S_RESP;
                    end
                end

                S_RESP: if (resp_ready) state <= S_IDLE;

                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
