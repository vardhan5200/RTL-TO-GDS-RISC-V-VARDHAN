// dm_cache.sv — explicit width on refill address
module dm_cache (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        req_valid,
    output logic        req_ready,
    input  logic [31:0] req_addr,
    output logic        resp_valid,
    output logic [31:0] resp_rdata,
    output logic        mem_re,
    output logic [31:0] mem_addr,
    input  logic [31:0] mem_rdata,
    // Optional write-through update port (store hit updates the cached word;
    // misses do not allocate). Defaults keep existing `.*` testbenches valid.
    input  logic        wr_en    = 1'b0,
    input  logic [31:0] wr_addr  = 32'h0,
    input  logic [31:0] wr_wdata = 32'h0,
    input  logic [3:0]  wr_strb  = 4'h0
);
    logic [31:0] data [0:63][0:3];
    logic [21:0] tag  [0:63];
    logic        valid[0:63];

    logic [5:0]  idx;
    logic [1:0]  word;
    logic        hit;
    logic [2:0]  cnt;
    logic [31:0] miss_addr;
    logic [1:0]  refill_word;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt <= 0;
            req_ready <= 1;
            resp_valid <= 0;
            for (int i = 0; i < 64; i++) valid[i] <= 0;
        end else begin
            resp_valid <= 0;

            if (cnt == 0 && wr_en && valid[wr_addr[9:4]] &&
                tag[wr_addr[9:4]] == wr_addr[31:10]) begin
                for (int b = 0; b < 4; b++)
                    if (wr_strb[b]) data[wr_addr[9:4]][wr_addr[3:2]][8*b +: 8] <= wr_wdata[8*b +: 8];
            end

            if (cnt == 0) begin
                if (req_valid && hit) begin
                    resp_rdata <= data[idx][word];
                    resp_valid <= 1;
                end else if (req_valid && !hit) begin
                    miss_addr <= req_addr;
                    cnt <= 1;
                    req_ready <= 0;
                end
            end else begin
                // refill_word is driven combinationally from cnt (below), so the
                // word written here matches the mem_addr that produced mem_rdata.
                data[miss_addr[9:4]][refill_word] <= mem_rdata;
                if (cnt == 4) begin
                    valid[miss_addr[9:4]] <= 1;
                    tag[miss_addr[9:4]]   <= miss_addr[31:10];
                    cnt <= 0;
                    req_ready <= 1;
                    // Last beat (word 3) is still being written this cycle:
                    // forward it from mem_rdata instead of the stale array.
                    resp_rdata <= (miss_addr[3:2] == 2'd3) ? mem_rdata
                                : data[miss_addr[9:4]][miss_addr[3:2]];
                    resp_valid <= 1;
                end else
                    cnt <= cnt + 1;
            end
        end
    end

    // Lookup is combinational (was blocking temps inside the always_ff, which
    // left `hit` holding the previous edge's value for anything probing it).
    assign idx  = req_addr[9:4];
    assign word = req_addr[3:2];
    assign hit  = valid[idx] && (tag[idx] == req_addr[31:10]);
    assign refill_word = cnt[1:0] - 2'd1;  // cnt 1..4 -> word 0..3
    assign mem_re   = (cnt != 0);
    assign mem_addr = {miss_addr[31:4], refill_word, 2'b00};
endmodule
