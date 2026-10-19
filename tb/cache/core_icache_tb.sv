// core_icache_tb.sv — core_top with the L1 I-cache in the fetch path.
// Program (built below): a 10-iteration loop (sum 10..1 = 55), a forward jal
// to another line, a call/return (jal/jalr) into a line that conflicts on the
// way back, and a jump to 0x90 that evicts the loop line (set 1). Checks
// architectural results, the exact retired-instruction count (no instruction
// lost or duplicated) and, every cycle, the fetch/stall contract:
//   * I$ miss (if_valid=0, no redirect) -> PC holds, a bubble enters ID
//   * every non-bubble instruction in ID equals mem[pc_id] (no bogus fetch)
// Run with -P core_icache_tb.USE_ICACHE=0 for the no-I$ reference.
`timescale 1ns/1ps
module core_icache_tb;
    parameter bit USE_ICACHE = 1'b1;
    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    logic [31:0] imem_addr, imem_rdata, dmem_addr, dmem_wdata, dmem_rdata;
    logic        dmem_re, dmem_we, mmu_fault;
    logic [3:0]  dmem_wstrb;
    logic [31:0] mem [0:4095];

    function automatic logic [31:0] addi(int rd, int rs1, int imm);
        return {imm[11:0], rs1[4:0], 3'b000, rd[4:0], 7'h13}; endfunction
    function automatic logic [31:0] add(int rd, int rs1, int rs2);
        return {7'h0, rs2[4:0], rs1[4:0], 3'b000, rd[4:0], 7'h33}; endfunction
    function automatic logic [31:0] sw(int rs2, int rs1, int imm);
        return {imm[11:5], rs2[4:0], rs1[4:0], 3'b010, imm[4:0], 7'h23}; endfunction
    function automatic logic [31:0] bne(int rs1, int rs2, int off);
        return {off[12], off[10:5], rs2[4:0], rs1[4:0], 3'b001, off[4:1], off[11], 7'h63}; endfunction
    function automatic logic [31:0] jal(int rd, int off);
        return {off[20], off[10:1], off[11], off[19:12], rd[4:0], 7'h6f}; endfunction
    function automatic logic [31:0] jalr(int rd, int rs1, int imm);
        return {imm[11:0], rs1[4:0], 3'b000, rd[4:0], 7'h67}; endfunction
    task automatic P(int a, logic [31:0] w); mem[a >> 2] = w; endtask

    initial begin
        for (int k = 0; k < 4096; k++) mem[k] = 32'h0000_0013;   // NOP
        P('h00, addi(1, 0, 0));        // sum
        P('h04, addi(2, 0, 10));       // i
        P('h08, addi(3, 0, 0));        // iterations
        P('h0C, add (1, 1, 2));        // loop:
        P('h10, addi(3, 3, 1));
        P('h14, addi(2, 2, -1));
        P('h18, bne (2, 0, -12));      //   -> 0x0C
        P('h1C, jal (0, 'h44));        // -> 0x60
        P('h20, addi(5, 0, 'h7FF));    // skipped
        P('h24, addi(5, 0, 'h7FF));    // skipped
        P('h28, addi(7, 0, 'h55));     // func:
        P('h2C, jalr(0, 6, 0));        //   return
        P('h60, sw  (1, 0, 'h200));
        P('h64, addi(4, 0, 1));
        P('h68, jal (6, -'h40));       // call 0x28
        P('h6C, sw  (7, 0, 'h204));
        P('h70, sw  (3, 0, 'h208));
        P('h74, jal (0, 'h1C));        // -> 0x90 (evicts set 1 = loop line)
        P('h78, addi(5, 0, 'h7FF));    // skipped
        P('h90, addi(9, 0, 9));
        P('h94, sw  (9, 0, 'h20C));
        P('h98, addi(8, 0, 1));
        P('h9C, sw  (8, 0, 'h3F0));    // signature
        P('hA0, jal (0, 0));           // spin
    end
    assign imem_rdata = mem[imem_addr[13:2]];
    assign dmem_rdata = mem[dmem_addr[13:2]];
    always @(posedge clk)
        if (dmem_we) for (int b = 0; b < 4; b++)
            if (dmem_wstrb[b]) mem[dmem_addr[13:2]][8*b +: 8] <= dmem_wdata[8*b +: 8];

    core_top #(.CACHE_BASE(32'h0), .CACHE_LIMIT(32'h200), .USE_MMU(1'b0),
               .USE_ICACHE(USE_ICACHE), .ICACHE_LINES(8)) dut (
        .clk, .rst_n, .imem_addr, .imem_rdata,
        .dmem_re, .dmem_we, .dmem_addr, .dmem_wdata, .dmem_wstrb, .dmem_rdata,
        .meip(1'b0), .mtip(1'b0), .msip(1'b0),
        .satp(32'h0), .priv_mode(2'b11), .mmu_fault);

    int cycles = 0, retired = 0, miss_cyc = 0, refills = 0, redir_busy = 0, contract_err = 0, done_cyc = -1;
    logic        prev_miss;
    logic [31:0] prev_pc;
    always @(posedge clk) if (rst_n) begin
        cycles <= cycles + 1;
        if (dut.retire && done_cyc < 0) retired <= retired + 1;
        if (dmem_we && dmem_addr == 32'h3F0 && done_cyc < 0) done_cyc <= cycles;
        if (!dut.if_valid) miss_cyc <= miss_cyc + 1;
        prev_miss <= !dut.if_valid && !dut.flush && !dut.stall;
        prev_pc   <= dut.pc;
    end
    generate if (USE_ICACHE) begin : g_cnt
        always @(posedge clk) if (rst_n) begin
            if (dut.g_icache.u_icache.cnt == 1) refills <= refills + 1;
            if (dut.flush && dut.g_icache.u_icache.busy) redir_busy <= redir_busy + 1;
        end
    end endgenerate
    // contract checks one step after each edge
    always @(negedge clk) if (rst_n && cycles > 0) begin
        if (prev_miss && !dut.bubble_id) begin
            contract_err++; $display("  FAIL @%0d: I$ miss but non-bubble entered ID", cycles); end
        if (prev_miss && dut.pc !== prev_pc) begin
            contract_err++; $display("  FAIL @%0d: PC moved during I$ miss", cycles); end
        if (!dut.bubble_id && dut.instr_id !== mem[dut.pc_id[13:2]]) begin
            contract_err++; $display("  FAIL @%0d: ID instr %h != mem[%h]", cycles, dut.instr_id, dut.pc_id); end
    end

    int pass_cnt = 0, fail_cnt = 0;
    task automatic chk(string name, logic [31:0] got, logic [31:0] exp);
        if (got === exp) begin pass_cnt++; $display("PASS  %-30s = 0x%0h", name, got); end
        else begin fail_cnt++; $display("FAIL  %-30s got 0x%0h exp 0x%0h", name, got, exp); end
    endtask
    task automatic chk_t(string name, bit ok);
        if (ok) begin pass_cnt++; $display("PASS  %s", name); end
        else begin fail_cnt++; $display("FAIL  %s", name); end
    endtask

    initial begin
        #22 rst_n = 1;
        while (done_cyc < 0 && cycles < 2000) @(posedge clk);
        repeat (5) @(posedge clk);
        $display("core I$ test (USE_ICACHE=%0d): signature at cycle %0d, retired=%0d, I$ refills=%0d, fetch-miss cycles=%0d, redirects during refill=%0d",
                 USE_ICACHE, done_cyc, retired, refills, miss_cyc, redir_busy);
        chk("x1 sum 10..1",          dut.regs[1], 55);
        chk("x3 loop iterations",    dut.regs[3], 10);
        chk("x4",                    dut.regs[4], 1);
        chk("x5 skipped instrs",     dut.regs[5], 0);
        chk("x6 link",               dut.regs[6], 32'h6C);
        chk("x7 func result",        dut.regs[7], 32'h55);
        chk("x9 after evicting jump",dut.regs[9], 9);
        chk("mem[0x200]",            mem['h200 >> 2], 55);
        chk("mem[0x204]",            mem['h204 >> 2], 32'h55);
        chk("mem[0x208]",            mem['h208 >> 2], 10);
        chk("mem[0x20C]",            mem['h20C >> 2], 9);
        chk("retired incl. signature sw", retired, 56);   // exact dynamic count
        chk_t($sformatf("fetch/stall contract held every cycle (%0d errors)", contract_err), contract_err == 0);
        if (USE_ICACHE) begin
            chk_t($sformatf("I$ misses stalled fetch (%0d miss cycles, %0d refills)", miss_cyc, refills),
                  refills >= 6 && miss_cyc >= 4 * 6);
            chk_t($sformatf("redirect during a refill exercised (%0d)", redir_busy), redir_busy >= 1);
            chk_t("loop body hit after first iteration (refills << dynamic fetches)", refills <= 10);
        end else
            chk_t("no I$: fetch never stalls", miss_cyc == 0);
        $display("SUMMARY: %0d PASS, %0d FAIL -> %s", pass_cnt, fail_cnt, fail_cnt == 0 ? "ALL PASS" : "FAILED");
        $finish;
    end
endmodule
