// icache_tb.sv — directed test for rtl/cache/icache.sv (8 lines x 16 B).
// Backing memory word[i] = 0xC0DE0000 | i. A monitor checks that EVERY cycle
// with fetch_valid=1 returns the right word for the current fetch_addr.
`timescale 1ns/1ps
module icache_tb;
    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    logic        fetch_req, fetch_valid, busy, inval, mem_re;
    logic [31:0] fetch_addr, fetch_rdata, mem_addr, mem_rdata;

    logic [31:0] backing [0:1023];
    initial for (int i = 0; i < 1024; i++) backing[i] = 32'hC0DE_0000 | i;
    function automatic logic [31:0] expw(logic [31:0] a); return 32'hC0DE_0000 | a[11:2]; endfunction

    icache #(.NLINES(8)) dut (.*);
    assign mem_rdata = backing[mem_addr[11:2]];

    int pass_cnt = 0, fail_cnt = 0, mon_err = 0, mem_reads = 0, hits_ok;
    always @(posedge clk) if (rst_n) begin
        if (fetch_valid && fetch_rdata !== expw(fetch_addr)) begin
            mon_err++;
            $display("FAIL  monitor: addr=%h rdata=%h exp %h", fetch_addr, fetch_rdata, expw(fetch_addr));
        end
        if (mem_re) mem_reads++;
    end

    task automatic check(bit ok, string msg);
        if (ok) begin pass_cnt++; $display("PASS  %s", msg); end
        else    begin fail_cnt++; $display("FAIL  %s", msg); end
    endtask

    // Present addr (changes on negedge) and count stall cycles until the cache
    // answers; the answer is sampled just before the posedge.
    task automatic fetch(input logic [31:0] a, input int exp_wait, input string what);
        int w = 0;
        fetch_addr = a; #1;
        while (!fetch_valid && w < 20) begin @(negedge clk); w++; #1; end
        check(fetch_valid && fetch_rdata === expw(a) && (exp_wait < 0 || w == exp_wait),
              $sformatf("%-32s addr=0x%03h data=%h (exp %h) wait=%0d (exp %0d)",
                        what, a, fetch_rdata, expw(a), w, exp_wait));
        @(negedge clk);
    endtask

    initial begin
        fetch_req = 0; inval = 0; fetch_addr = 0;
        #22 rst_n = 1;
        @(negedge clk);
        fetch_req = 1;

        // miss then hit on the same instruction address
        fetch(32'h000, 4, "miss  line0 w0 (cold)");
        fetch(32'h000, 0, "hit   line0 w0 (same addr)");
        fetch(32'h004, 0, "hit   line0 w1");
        fetch(32'h008, 0, "hit   line0 w2");
        fetch(32'h00C, 0, "hit   line0 w3");
        // miss on word 3: answered by last-beat forwarding from mem_rdata
        fetch(32'h01C, 4, "miss  line1 w3 (last-beat fwd)");
        fetch(32'h010, 0, "hit   line1 w0");
        // miss on word 1: answered from array on last beat
        fetch(32'h024, 4, "miss  line2 w1");
        fetch(32'h028, 0, "hit   line2 w2");

        // redirect during a refill: PC leaves line 0x40 for cached 0x004.
        // Stale 0x40 data must never be returned for 0x004 (monitor), the
        // refill completes, then 0x004 hits and 0x40 line is valid.
        fetch_addr = 32'h040; @(negedge clk); @(negedge clk);   // refill in flight
        check(busy, "refill in progress before redirect");
        fetch(32'h004, -1, "redirect to 0x004 during refill");
        fetch(32'h048, 0, "hit   line4 (refilled under redirect)");

        // conflict: 0x080 maps to index 0 -> evicts line 0
        fetch(32'h084, 4, "miss  0x080 line (evicts idx0)");
        fetch(32'h080, 0, "hit   0x080 line w0");
        fetch(32'h000, 4, "miss  line0 again after eviction");

        // fill all 8 sets, then every word of every set must hit
        for (int l = 0; l < 8; l++) fetch(l * 16, -1, $sformatf("fill  set %0d", l));
        begin
            hits_ok = 1;
            for (int a = 0; a < 128; a += 4) begin
                fetch_addr = a; #1;
                if (!fetch_valid || fetch_rdata !== expw(a)) hits_ok = 0;
                @(negedge clk);
            end
            check(hits_ok, "all 32 words of 8 sets hit with 0 wait");
        end

        // invalidate (FENCE.I hook): next fetch misses again
        inval = 1; @(negedge clk); inval = 0;
        fetch(32'h010, 4, "miss  after inval");

        // fetch_req=0: no refill started on a miss
        fetch_req = 0; fetch_addr = 32'h300; repeat (3) @(negedge clk);
        check(!busy && !fetch_valid, "fetch_req=0 does not start a refill");
        fetch_req = 1;
        fetch(32'h300, 4, "miss  0x300 after fetch_req back");

        check(mon_err == 0, $sformatf("monitor: no wrong data on any valid cycle (%0d errors)", mon_err));
        $display("info: %0d memory reads", mem_reads);
        if (mon_err) fail_cnt++;
        $display("SUMMARY: %0d PASS, %0d FAIL -> %s", pass_cnt, fail_cnt, fail_cnt == 0 ? "ALL PASS" : "FAILED");
        $finish;
    end
endmodule
