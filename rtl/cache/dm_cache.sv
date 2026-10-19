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
    input  logic [31:0] mem_rdata
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
            idx  = req_addr[9:4];
            word = req_addr[3:2];
            hit  = valid[idx] && (tag[idx] == req_addr[31:10]);
            resp_valid <= 0;

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
                refill_word = cnt - 1;
                data[miss_addr[9:4]][refill_word] <= mem_rdata;
                if (cnt == 4) begin
                    valid[miss_addr[9:4]] <= 1;
                    tag[miss_addr[9:4]]   <= miss_addr[31:10];
                    cnt <= 0;
                    req_ready <= 1;
                    resp_rdata <= data[miss_addr[9:4]][miss_addr[3:2]];
                    resp_valid <= 1;
                end else
                    cnt <= cnt + 1;
            end
        end
    end

    assign mem_re   = (cnt != 0);
    assign mem_addr = {miss_addr[31:4], refill_word, 2'b00};
endmodule
