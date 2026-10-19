// tb_sv32_mmu.sv — self-checking testbench for the Sv32 MMU skeleton
//
// Run (Icarus Verilog, from the repo root):
//   iverilog -g2012 -s tb_sv32_mmu -o /tmp/mmu.vvp rtl/mmu/*.sv tb/mmu/tb_sv32_mmu.sv
//   vvp /tmp/mmu.vvp
// or: sh tb/mmu/run.sh
// Ends with "MMU: ALL TESTS PASSED" or "MMU: <n> FAILURES" (and $fatal).
//
// Hand-built page table (physical addresses, 64 KiB behavioural memory):
//   satp = 0x8000_0001  -> MODE=Sv32, root table PPN 0x1 at PA 0x1000
//   root[1]  @0x1004 = 0x0000_0801  pointer -> L0 table at PA 0x2000
//   root[2]  @0x1008 = 0x04B0_00CF  megapage PPN 0x12C00, VRWXAD
//   root[3]  @0x100C = 0x0010_04C3  megapage PPN 0x00401 (misaligned)
//   root[4]  @0x1010 = 0x0004_0001  pointer -> PA 0x100000 (unmapped)
//   L0[3]    @0x200C = 0x048D_14C7  4K page PPN 0x12345, VRWAD
//   L0[4]    @0x2010 = 0x0001_54C3  4K page PPN 0x00055, VRAD (read-only)
//   L0[5]    @0x2014 = 0x0000_0000  invalid (V=0)
//   L0[6]    @0x2018 = 0x0001_DC05  reserved (W=1, R=0)
//   L0[7]    @0x201C = 0x0002_6407  PPN 0x99, VRW, A=0
//   L0[8]    @0x2020 = 0x0002_6847  PPN 0x9A, VRWA, D=0
//   L0[9]    @0x2024 = 0x0002_6CD7  PPN 0x9B, VRWUAD (user page)
//   L0[10]   @0x2028 = 0x0000_0801  pointer at level 0 (invalid)
//   Main check: VA 0x0040_3123 -> PA 0x1234_5123
`timescale 1ns/1ps

module tb_sv32_mmu;
    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    logic [31:0] satp;
    logic [1:0]  priv;
    logic        sum, mxr, flush;
    logic        req_valid, req_ready;
    logic [31:0] req_vaddr;
    logic [1:0]  req_acc;
    logic        resp_valid, resp_ready;
    logic [33:0] resp_paddr;
    logic        resp_page_fault, resp_access_fault;
    logic [3:0]  resp_cause;
    logic        mem_req_valid, mem_req_ready, mem_resp_valid, mem_resp_ready, mem_resp_error;
    logic [33:0] mem_req_addr;
    logic [31:0] mem_resp_rdata;

    sv32_mmu #(.TLB_ENTRIES(4)) dut (.*);

    // ---------------- behavioural PT memory (ready/valid, 1-cycle latency) ----
    logic [31:0] mem [0:16383];   // 64 KiB at PA 0x0
    int          reads = 0;
    logic        toggle;

    // backpressure: mem_req_ready alternates every cycle
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            toggle         <= 0;
            mem_resp_valid <= 0;
            mem_resp_rdata <= 0;
            mem_resp_error <= 0;
        end else begin
            toggle <= ~toggle;
            if (mem_resp_valid && mem_resp_ready) mem_resp_valid <= 0;
            if (mem_req_valid && mem_req_ready) begin
                reads          <= reads + 1;
                mem_resp_valid <= 1;
                mem_resp_error <= (mem_req_addr[33:16] != 0);
                mem_resp_rdata <= (mem_req_addr[33:16] != 0) ? 32'hDEAD_BEEF
                                                              : mem[mem_req_addr[15:2]];
            end
        end
    end
    assign mem_req_ready = toggle;

    localparam logic [1:0] LD = 2'd0, ST = 2'd1, IF = 2'd2;
    localparam logic [1:0] PU = 2'b00, PS = 2'b01, PM = 2'b11;

    int errors = 0, tests = 0;

    // exp_fault: 0 none, 1 page fault, 2 access fault; exp_reads < 0 = don't care
    task automatic xlate(input logic [31:0] va, input logic [1:0] acc,
                         input logic [33:0] exp_pa, input int exp_fault,
                         input logic [3:0] exp_cause, input int exp_reads,
                         input string name);
        int r0, nr;
        logic ok;
        r0 = reads;
        @(negedge clk);
        req_valid = 1; req_vaddr = va; req_acc = acc;
        while (!req_ready) @(negedge clk);
        @(posedge clk); #1 req_valid = 0;
        while (!resp_valid) @(negedge clk);
        nr = reads - r0;
        ok = 1;
        if (resp_page_fault !== (exp_fault == 1)) ok = 0;
        if (resp_access_fault !== (exp_fault == 2)) ok = 0;
        if (exp_fault == 0 && resp_paddr !== exp_pa) ok = 0;
        if (exp_fault != 0 && resp_cause !== exp_cause) ok = 0;
        if (exp_reads >= 0 && nr != exp_reads) ok = 0;
        tests++;
        if (ok)
            $display("PASS %-34s va=%h pa=%h pf=%0d af=%0d cause=%0d walk_reads=%0d",
                     name, va, resp_paddr, resp_page_fault, resp_access_fault, resp_cause, nr);
        else begin
            errors++;
            $display("FAIL %-34s va=%h pa=%h (exp %h) pf=%0d af=%0d (exp fault %0d) cause=%0d (exp %0d) walk_reads=%0d (exp %0d)",
                     name, va, resp_paddr, exp_pa, resp_page_fault, resp_access_fault,
                     exp_fault, resp_cause, exp_cause, nr, exp_reads);
        end
        @(posedge clk);
    endtask

    task automatic do_flush();
        @(negedge clk); flush = 1;
        @(negedge clk); flush = 0;
    endtask

    initial begin
        satp = 0; priv = PS; sum = 0; mxr = 0; flush = 0;
        req_valid = 0; req_vaddr = 0; req_acc = LD; resp_ready = 1;
        for (int i = 0; i < 16384; i++) mem[i] = 32'b0;

        mem[32'h1004 >> 2] = 32'h0000_0801;
        mem[32'h1008 >> 2] = 32'h04B0_00CF;
        mem[32'h100C >> 2] = 32'h0010_04C3;
        mem[32'h1010 >> 2] = 32'h0004_0001;
        mem[32'h200C >> 2] = 32'h048D_14C7;
        mem[32'h2010 >> 2] = 32'h0001_54C3;
        mem[32'h2014 >> 2] = 32'h0000_0000;
        mem[32'h2018 >> 2] = 32'h0001_DC05;
        mem[32'h201C >> 2] = 32'h0002_6407;
        mem[32'h2020 >> 2] = 32'h0002_6847;
        mem[32'h2024 >> 2] = 32'h0002_6CD7;
        mem[32'h2028 >> 2] = 32'h0000_0801;

        #20 rst_n = 1;

        // ---- bare mode ----
        xlate(32'h1234_5678, LD, 34'h0_1234_5678, 0, 0, 0, "bare: satp.MODE=0 passthrough");

        satp = 32'h8000_0001;
        priv = PM;
        xlate(32'h0040_3123, LD, 34'h0_0040_3123, 0, 0, 0, "bare: M-mode passthrough");
        priv = PS;

        // ---- 4 KiB translation + TLB hit ----
        xlate(32'h0040_3123, LD, 34'h0_1234_5123, 0, 0, 2, "4K load (walk 2 levels)");
        xlate(32'h0040_3123, LD, 34'h0_1234_5123, 0, 0, 0, "4K load again (TLB hit)");
        xlate(32'h0040_3FFC, ST, 34'h0_1234_5FFC, 0, 0, 0, "4K store same page (TLB hit)");

        // ---- megapage ----
        xlate(32'h0080_0ABC, LD, 34'h0_12C0_0ABC, 0, 0, 1, "4M megapage load (walk 1 level)");
        xlate(32'h00BF_FFF0, IF, 34'h0_12FF_FFF0, 0, 0, 0, "4M megapage fetch (TLB hit)");
        xlate(32'h00C0_0000, LD, 0, 1, 13, 1, "misaligned megapage -> PF");

        // ---- invalid PTEs ----
        xlate(32'h0040_5000, LD, 0, 1, 13, 2, "invalid PTE V=0 -> load PF");
        xlate(32'h0040_6000, IF, 0, 1, 12, 2, "reserved W=1,R=0 -> fetch PF");
        xlate(32'h0040_A000, LD, 0, 1, 13, 2, "pointer PTE at level 0 -> PF");
        xlate(32'h0100_0000, LD, 0, 2, 5,  2, "PTE read bus error -> access flt");

        // ---- permissions ----
        xlate(32'h0040_4010, LD, 34'h0_0005_5010, 0, 0, 2, "read-only page load");
        xlate(32'h0040_4010, ST, 0, 1, 15, 0, "store to RO page (TLB hit) -> PF");
        do_flush();
        xlate(32'h0040_4010, ST, 0, 1, 15, 2, "store to RO page (walk) -> PF");
        xlate(32'h0040_3000, IF, 0, 1, 12, -1, "fetch from non-X page -> PF");
        xlate(32'h0040_7000, LD, 0, 1, 13, 2, "A=0 -> load PF");
        xlate(32'h0040_8004, LD, 34'h0_0009_A004, 0, 0, 2, "D=0 page load OK");
        xlate(32'h0040_8004, ST, 0, 1, 15, 0, "D=0 page store -> PF");
        xlate(32'h0040_9000, LD, 0, 1, 13, 2, "S load from U page, SUM=0 -> PF");
        sum = 1;
        xlate(32'h0040_9000, LD, 34'h0_0009_B000, 0, 0, 2, "S load from U page, SUM=1 OK");
        xlate(32'h0040_9000, IF, 0, 1, 12, 0, "S fetch from U page -> PF");
        sum = 0;
        priv = PU;
        xlate(32'h0040_9008, ST, 34'h0_0009_B008, 0, 0, 0, "U store to U page OK");
        xlate(32'h0040_8000, LD, 0, 1, 13, -1, "U load from S page -> PF");
        priv = PS;

        // ---- flush then re-walk ----
        do_flush();
        xlate(32'h0040_3123, LD, 34'h0_1234_5123, 0, 0, 2, "after flush: re-walk");
        mem[32'h200C >> 2] = 32'h150C_84C7;      // remap L0[3] -> PPN 0x54321
        xlate(32'h0040_3123, LD, 34'h0_1234_5123, 0, 0, 0, "PTE changed, stale TLB hit");
        do_flush();
        xlate(32'h0040_3123, LD, 34'h0_5432_1123, 0, 0, 2, "flush -> re-walk sees new PTE");

        // ---- replacement: 5 distinct pages through a 4-entry TLB ----
        do_flush();
        xlate(32'h0040_3000, LD, 34'h0_5432_1000, 0, 0, 2, "fill e0");
        xlate(32'h0040_4000, LD, 34'h0_0005_5000, 0, 0, 2, "fill e1");
        xlate(32'h0040_8000, LD, 34'h0_0009_A000, 0, 0, 2, "fill e2");
        xlate(32'h0080_0000, LD, 34'h0_12C0_0000, 0, 0, 1, "fill e3 (mega)");
        xlate(32'h0040_4000, LD, 34'h0_0005_5000, 0, 0, 0, "e1 still hits");
        sum = 1;
        xlate(32'h0040_9000, LD, 34'h0_0009_B000, 0, 0, 2, "5th page evicts e0 (round robin)");
        sum = 0;
        xlate(32'h0040_3000, LD, 34'h0_5432_1000, 0, 0, 2, "e0 evicted -> re-walk");

        $display("----------------------------------------");
        if (errors == 0) $display("MMU: ALL TESTS PASSED (%0d tests)", tests);
        else begin
            $display("MMU: %0d FAILURES (of %0d tests)", errors, tests);
            $fatal(1, "tb_sv32_mmu failed");
        end
        $finish;
    end

    initial begin
        #200000;
        $display("MMU: TIMEOUT");
        $fatal(1, "tb_sv32_mmu timeout");
    end
endmodule
