// dm_cache_refill_tb.sv — directed refill/hit data-path test for dm_cache.
// Backing memory: word[i] = i. Every read is checked against addr>>2.
`timescale 1ns/1ps
module dm_cache_refill_tb;
    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    logic        req_valid, req_ready, resp_valid, mem_re;
    logic [31:0] req_addr, resp_rdata, mem_addr, mem_rdata;

    logic [31:0] backing [0:1023];
    initial for (int i = 0; i < 1024; i++) backing[i] = i;  // word i contains i

    dm_cache dut (.*);
    assign mem_rdata = backing[mem_addr[11:2]];

    int pass_cnt = 0, fail_cnt = 0;

    // Issue one read; inputs change on negedge, result checked on the negedge
    // after the posedge that raised resp_valid. Consecutive calls are
    // back-to-back (req_valid stays high between them).
    task automatic rd(input logic [31:0] a, input string what);
        int cycles = 0;
        logic [31:0] exp = a >> 2;
        req_valid = 1; req_addr = a;
        do begin
            @(negedge clk); cycles++;
        end while (!resp_valid && cycles < 50);
        if (resp_valid && resp_rdata === exp) begin
            pass_cnt++;
            $display("PASS  %-28s addr=0x%04h data=%0d (exp %0d) cycles=%0d", what, a, resp_rdata, exp, cycles);
        end else begin
            fail_cnt++;
            $display("FAIL  %-28s addr=0x%04h data=%0d (exp %0d) resp_valid=%b cycles=%0d", what, a, resp_rdata, exp, resp_valid, cycles);
        end
    endtask

    initial begin
        req_valid = 0; req_addr = 0;
        #22 rst_n = 1;
        @(negedge clk);

        // Line 0 (idx 0): miss on word 0, then hits on all words back-to-back
        rd(32'h000, "miss line0 w0");
        rd(32'h004, "hit  line0 w1 (b2b)");
        rd(32'h008, "hit  line0 w2");
        rd(32'h00C, "hit  line0 w3");
        rd(32'h000, "hit  line0 w0");

        // Line 1 (idx 1): second refill, check all words
        rd(32'h010, "miss line1 w0");
        rd(32'h014, "hit  line1 w1");
        rd(32'h018, "hit  line1 w2");
        rd(32'h01C, "hit  line1 w3");

        // Line 2: miss on non-zero word (critical word = 2)
        rd(32'h028, "miss line2 w2");
        rd(32'h020, "hit  line2 w0");
        rd(32'h024, "hit  line2 w1");
        rd(32'h02C, "hit  line2 w3");

        // Line 3: miss on last word (word being written on final refill beat)
        rd(32'h03C, "miss line3 w3");
        rd(32'h030, "hit  line3 w0");
        rd(32'h038, "hit  line3 w2");

        // Conflict: addr 0x400 maps to idx 0 with a different tag -> eviction
        rd(32'h404, "miss evict idx0 (tag1) w1");
        rd(32'h400, "hit  idx0 tag1 w0");
        rd(32'h408, "hit  idx0 tag1 w2");
        rd(32'h40C, "hit  idx0 tag1 w3");
        rd(32'h000, "miss reload line0 w0");
        rd(32'h00C, "hit  line0 w3 after reload");

        // Earlier lines must be untouched by other refills
        rd(32'h014, "hit  line1 w1 (still)");
        rd(32'h028, "hit  line2 w2 (still)");

        // Idle gap then hit
        req_valid = 0; repeat (3) @(negedge clk);
        rd(32'h034, "hit  line3 w1 after idle");
        req_valid = 0;

        $display("SUMMARY: %0d PASS, %0d FAIL -> %s", pass_cnt, fail_cnt, fail_cnt == 0 ? "ALL PASS" : "FAILED");
        $finish;
    end
endmodule
