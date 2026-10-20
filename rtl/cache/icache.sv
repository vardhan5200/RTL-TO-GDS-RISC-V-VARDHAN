// icache.sv — small direct-mapped, read-only L1 instruction cache.
//   * NLINES lines (default 8) x 4 words (16 B/line) = 128 B by default.
//   * Physically indexed / physically tagged: fetch_addr must be the
//     translated physical fetch address (core_top: after the I-MMU / fetch
//     translation register). satp / privilege changes need no invalidation.
//     (NLINES*16 B <= 4 KiB, so the index is also inside the page offset.)
//   * Combinational hit path (same timing as the old combinational imem):
//     fetch_valid/fetch_rdata are valid in the same cycle as fetch_addr.
//   * Miss: a 4-beat refill over the mem_* port (combinational-read memory,
//     one word per cycle). Same style as dm_cache.sv: refill_word is derived
//     combinationally from the beat counter (so mem_addr and the written word
//     always agree) and the last beat is forwarded: in the final refill cycle
//     a fetch that targets the refilled line is answered (word 3 straight from
//     mem_rdata, words 0..2 from the array written in earlier beats).
//   * The response is always computed for the *current* fetch_addr, so if the
//     core redirects (branch/trap) during a refill, the refill just completes
//     (filling a valid line) and the stale line is never returned for the new
//     PC; the new PC then hits or misses on its own.
//   * fetch_req=0 suppresses starting a new refill (e.g. on a redirect cycle).
//   * inval: invalidate all lines (FENCE.I). Takes effect immediately, also
//     while a refill is in flight: that refill is then neither forwarded
//     nor marked valid (it may hold pre-FENCE.I data).
//   No coherence with stores: self-modifying code needs FENCE.I (inval).
module icache #(
    parameter int NLINES = 8
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        fetch_req,
    input  logic [31:0] fetch_addr,
    output logic        fetch_valid,
    output logic [31:0] fetch_rdata,
    output logic        busy,        // refill in progress
    input  logic        inval,
    output logic        mem_re,
    output logic [31:0] mem_addr,
    input  logic [31:0] mem_rdata
);
    localparam int IW = (NLINES > 1) ? $clog2(NLINES) : 1;
    localparam int TW = 32 - 4 - IW;

    logic [31:0]   data  [0:NLINES-1][0:3];
    logic [TW-1:0] tag   [0:NLINES-1];
    logic          valid [0:NLINES-1];

    logic [2:0]    cnt;          // 0 = idle, 1..4 = refill beat
    logic [31:0]   miss_addr;
    logic [1:0]    refill_word;
    logic [IW-1:0] idx, midx;
    logic [1:0]    word;
    logic          hit, fwd;
    logic          kill;         // inval seen during the current refill

    assign idx  = fetch_addr[4 +: IW];
    assign word = fetch_addr[3:2];
    assign midx = miss_addr[4 +: IW];
    assign hit  = (cnt == 0) && valid[idx] && (tag[idx] == fetch_addr[31 -: TW]);
    // last refill beat for the line the current PC is in
    assign fwd  = (cnt == 4) && !kill && !inval && (fetch_addr[31:4] == miss_addr[31:4]);

    assign fetch_valid = hit || fwd;
    assign fetch_rdata = (fwd && word == 2'd3) ? mem_rdata : data[idx][word];

    assign refill_word = cnt[1:0] - 2'd1;     // cnt 1..4 -> word 0..3
    assign mem_re      = (cnt != 0);
    assign mem_addr    = {miss_addr[31:4], refill_word, 2'b00};
    assign busy        = (cnt != 0);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt <= 0;
            miss_addr <= 0;
            kill <= 0;
            for (int i = 0; i < NLINES; i++) valid[i] <= 0;
        end else if (cnt == 0) begin
            if (inval) begin
                for (int i = 0; i < NLINES; i++) valid[i] <= 0;
            end else if (fetch_req && !hit) begin
                miss_addr  <= fetch_addr;
                valid[idx] <= 0;      // line is being overwritten
                cnt        <= 1;
                kill       <= 0;
            end
        end else begin
            if (inval) begin
                for (int i = 0; i < NLINES; i++) valid[i] <= 0;
                kill <= 1;
            end
            data[midx][refill_word] <= mem_rdata;
            if (cnt == 4) begin
                valid[midx] <= !(inval || kill);
                tag[midx]   <= miss_addr[31 -: TW];
                cnt         <= 0;
                kill        <= 0;
            end else
                cnt <= cnt + 1;
        end
    end
endmodule
