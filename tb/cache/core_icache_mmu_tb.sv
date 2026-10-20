// core_icache_mmu_tb.sv — L1 I-cache behind Sv32 fetch translation (core_top,
// USE_MMU=1; the program drops from M to S-mode via MRET at reset so fetch is
// translated once satp is set). Flat 32 KiB memory shared by fetch and data. Sv32 map (root PA 0x2000,
// L1[0] -> L0 at PA 0x3000):
//   VA 0x0000 -> PA 0x0000 RWX  main program, trap handler (0x140), log, signature
//   VA 0x1000 -> PA 0x5000 RX   code A   (PA 0x1000 holds decoy code)
//   VA 0x4000    invalid        fetch page fault target (PA 0x4000 holds decoy)
//   VA 0x5000 -> PA 0x5000 RW   data alias of code A (for the code patch)
//   VA 0x6000 -> PA 0x5000 RX   second virtual alias of code A (PA 0x6000 decoy)
// Program: enable satp; call VA 0x1000 (I$ miss, refill of PA 0x5000), call
// again (hit), call the alias VA 0x6000 (hit: same physical line); jump to VA
// 0x4000 twice (mcause 12, mtval = mepc = 0x4000, no refill); patch code A's
// 3rd word through VA 0x5008, FENCE.I, call VA 0x1000 (patched code runs).
// Checks every cycle that each instruction entering ID equals mem[PA(pc_id)],
// and that I$ refills only ever use translated, mapped physical addresses.
// Run with -P core_icache_mmu_tb.USE_ICACHE=0 for the uncached reference.
`timescale 1ns/1ps
module core_icache_mmu_tb;
    parameter bit USE_ICACHE = 1'b1;
    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    logic [31:0] imem_addr, imem_rdata, dmem_addr, dmem_wdata, dmem_rdata;
    logic        dmem_re, dmem_we, mmu_fault;
    logic [3:0]  dmem_wstrb;
    logic [1:0]  cur_priv;
    logic [31:0] mem [0:8191];

    // ---- tiny assembler ----
    function automatic logic [31:0] addi(int rd, int rs1, int imm);
        return {imm[11:0], rs1[4:0], 3'b000, rd[4:0], 7'h13}; endfunction
    function automatic logic [31:0] lui(int rd, int imm20);
        return {imm20[19:0], rd[4:0], 7'h37}; endfunction
    function automatic logic [31:0] sw(int rs2, int rs1, int imm);
        return {imm[11:5], rs2[4:0], rs1[4:0], 3'b010, imm[4:0], 7'h23}; endfunction
    function automatic logic [31:0] jal(int rd, int off);
        return {off[20], off[10:1], off[11], off[19:12], rd[4:0], 7'h6f}; endfunction
    function automatic logic [31:0] jalr(int rd, int rs1, int imm);
        return {imm[11:0], rs1[4:0], 3'b000, rd[4:0], 7'h67}; endfunction
    function automatic logic [31:0] csrrw(int rd, int csr, int rs1);
        return {csr[11:0], rs1[4:0], 3'b001, rd[4:0], 7'h73}; endfunction
    function automatic logic [31:0] csrrs(int rd, int csr, int rs1);
        return {csr[11:0], rs1[4:0], 3'b010, rd[4:0], 7'h73}; endfunction
    localparam logic [31:0] MRET = 32'h3020_0073, FENCE_I = 32'h0000_100F;
    localparam int MSTATUS = 'h300, SATP = 'h180, MTVEC = 'h305, MEPC = 'h341, MCAUSE = 'h342, MTVAL = 'h343;
    localparam logic [31:0] PATCH = 32'h0770_0613;           // addi x12, x0, 0x77
    localparam logic [31:0] SIG   = 32'h1FE7_C00D;
    task automatic P(int a, logic [31:0] w); mem[a >> 2] = w; endtask

    initial begin
        for (int k = 0; k < 8192; k++) mem[k] = 32'h0000_0013;              // NOPs
        for (int k = 'h2000 >> 2; k < ('h4000 >> 2); k++) mem[k] = 32'h0;   // page tables
        // main (VA = PA page 0)
        P('h00, jal (0, 'h80));                                    // -> S-mode entry stub (0x80)
        P('h04, addi(1, 1, 2));                                    // x1 = satp value
        P('h08, addi(31, 0, 'h300));                               // trap log pointer
        P('h0C, addi(0, 0, 0));         P('h10, addi(0, 0, 0));    // (mtvec set in the M-mode stub)
        P('h14, csrrw(0, SATP, 1));                                // Sv32 on (flush, refetch)
        P('h18, lui (6, 1));                                       // x6 = VA 0x1000
        P('h1C, jalr(1, 6, 0));                                    // call A: I$ miss
        P('h20, jalr(1, 6, 0));                                    // call A: hit
        P('h24, lui (7, 6));            P('h28, jalr(1, 7, 0));    // alias VA 0x6000: hit
        P('h2C, lui (8, 4));            P('h30, jalr(1, 8, 0));    // VA 0x4000: fetch PF
        P('h34, jalr(1, 8, 0));                                    // again: fetch PF
        P('h38, lui (9, 5));                                       // x9 = VA 0x5000 (RW alias)
        P('h3C, lui (13, 'h07700));     P('h40, addi(13, 13, 'h613)); // x13 = PATCH
        P('h44, sw  (13, 9, 8));                                   // PA 0x5008 = PATCH
        P('h48, FENCE_I);
        P('h4C, jalr(1, 6, 0));                                    // call A: patched code
        P('h50, csrrs(20, SATP, 0));
        P('h54, lui (22, 'h1FE7C));     P('h58, addi(22, 22, 'h00D));
        P('h5C, sw  (22, 0, 'h3F0));                               // signature
        P('h60, jal (0, 0));
        // S-mode entry stub (M-mode, Bare): x1 = 0x80000000, mtvec = 0x140,
        // mstatus.MPP = S, mepc = 0x04, MRET -> main continues at 0x04 in S-mode
        P('h80, lui (1, 'h80000));      P('h84, addi(5, 0, 'h140)); P('h88, csrrw(0, MTVEC, 5));
        P('h8C, lui (5, 1));            P('h90, addi(5, 5, -2048)); P('h94, csrrw(0, MSTATUS, 5));
        P('h98, addi(5, 0, 4));         P('h9C, csrrw(0, MEPC, 5)); P('hA0, MRET);
        // trap handler (VA = PA 0x140): log {mcause, mtval, mepc}, return to ra
        P('h140, csrrs(25, MCAUSE, 0)); P('h144, csrrs(26, MTVAL, 0)); P('h148, csrrs(27, MEPC, 0));
        P('h14C, sw(25, 31, 0));        P('h150, sw(26, 31, 4));       P('h154, sw(27, 31, 8));
        P('h158, addi(31, 31, 12));     P('h15C, addi(24, 24, 1));
        P('h160, csrrw(0, MEPC, 1));    P('h164, MRET);
        // code A at PA 0x5000
        P('h5000, addi(10, 10, 1));     P('h5004, addi(11, 0, 'hA2));
        P('h5008, addi(12, 0, 'hA3));   P('h500C, jalr(0, 1, 0));
        // decoys at the untranslated PAs: must never execute
        P('h1000, addi(29, 0, 'hBAD));  P('h1004, jalr(0, 1, 0));
        P('h4000, addi(29, 0, 'hBAD));  P('h4004, jalr(0, 1, 0));
        P('h6000, addi(29, 0, 'hBAD));  P('h6004, jalr(0, 1, 0));
        // page tables
        mem['h2000 >> 2] = 32'h0000_0C01;   // L1[0] -> L0 at PA 0x3000
        mem['h3000 >> 2] = 32'h0000_00CF;   // VA 0x0000 -> PA 0x0000 V|R|W|X|A|D
        mem['h3004 >> 2] = 32'h0000_14CB;   // VA 0x1000 -> PA 0x5000 V|R|X|A|D
        mem['h3010 >> 2] = 32'h0000_0000;   // VA 0x4000 invalid
        mem['h3014 >> 2] = 32'h0000_14C7;   // VA 0x5000 -> PA 0x5000 V|R|W|A|D
        mem['h3018 >> 2] = 32'h0000_14CB;   // VA 0x6000 -> PA 0x5000 V|R|X|A|D
    end
    assign imem_rdata = mem[imem_addr[14:2]];
    assign dmem_rdata = mem[dmem_addr[14:2]];
    always @(posedge clk)
        if (dmem_we) for (int b = 0; b < 4; b++)
            if (dmem_wstrb[b]) mem[dmem_addr[14:2]][8*b +: 8] <= dmem_wdata[8*b +: 8];

    core_top #(.CACHE_BASE(32'h0), .CACHE_LIMIT(32'h200), .USE_MMU(1'b1),
               .USE_ICACHE(USE_ICACHE), .ICACHE_LINES(8)) dut (
        .clk, .rst_n, .imem_addr, .imem_rdata,
        .dmem_re, .dmem_we, .dmem_addr, .dmem_wdata, .dmem_wstrb, .dmem_rdata,
        .meip(1'b0), .mtip(1'b0), .msip(1'b0),
        .mmu_fault, .cur_priv);

    // VA -> PA of this map (page 0 is identity, so it also covers Bare fetch)
    function automatic logic [31:0] va2pa(logic [31:0] va);
        case (va[31:12])
            20'h0:         return va;
            20'h1, 20'h6:  return {20'h5, va[11:0]};
            default:       return 32'hFFFF_FFFF;
        endcase
    endfunction

    int cycles = 0, done_cyc = -1, traps = 0, contract_err = 0, fault_ids = 0;
    int refills = 0, refills_a = 0, refills_bad = 0, hits_a = 0, misscyc_a = 0;
    bit bad_tag, a_valid_at_fencei = 0, fencei_seen = 0, refill_a_after_fencei = 0;
    always @(posedge clk) if (rst_n) begin
        cycles <= cycles + 1;
        if (dmem_we && dmem_addr == 32'h3F0 && done_cyc < 0) done_cyc <= cycles;
        if (dut.p_trap) begin
            traps <= traps + 1;
            $display("  trap @pc %08h: mcause=%0d mtval=%08h", dut.pc_ex, dut.p_cause, dut.xcpt_tval_c);
        end
        if (dut.fault_id && !dut.bubble_id) fault_ids <= fault_ids + 1;
    end
    // every instruction entering ID must be the word at the translated PA
    always @(negedge clk) if (rst_n && cycles > 0)
        if (!dut.bubble_id && !dut.fault_id && dut.instr_id !== mem[va2pa(dut.pc_id) >> 2]) begin
            contract_err++;
            $display("  FAIL @%0d: ID instr %h != mem[PA %h] for VA %h", cycles, dut.instr_id,
                     va2pa(dut.pc_id), dut.pc_id);
        end
    generate if (USE_ICACHE) begin : g_ic
        always @(posedge clk) if (rst_n) begin
            if (dut.g_icache.u_icache.cnt == 1) begin
                refills <= refills + 1;
                $display("  I$ refill PA %08h (pc VA %08h)", dut.g_icache.u_icache.miss_addr, dut.pc);
                if (dut.g_icache.u_icache.miss_addr[31:4] == 28'h500) begin
                    refills_a <= refills_a + 1;
                    if (fencei_seen) refill_a_after_fencei <= 1;
                end
                // only PA pages 0 (main/handler) and 5 (code A) may be refilled
                if (dut.g_icache.u_icache.miss_addr[31:12] != 0 &&
                    dut.g_icache.u_icache.miss_addr[31:12] != 5) refills_bad <= refills_bad + 1;
            end
            if (dut.g_icache.u_icache.hit && dut.if_xl_ok && !dut.if_fault && !dut.stall &&
                dut.if_pa[31:12] == 20'h5) hits_a <= hits_a + 1;
            if (dut.fencei_inval) begin
                fencei_seen <= 1;
                a_valid_at_fencei <= dut.g_icache.u_icache.valid[0] &&
                                     dut.g_icache.u_icache.tag[0] == (32'h5000 >> 7);
            end
        end
    end endgenerate

    int pass_cnt = 0, fail_cnt = 0;
    task automatic chk(string name, logic [31:0] got, logic [31:0] exp);
        if (got === exp) begin pass_cnt++; $display("PASS  %-40s = 0x%0h", name, got); end
        else begin fail_cnt++; $display("FAIL  %-40s got 0x%0h exp 0x%0h", name, got, exp); end
    endtask
    task automatic chk_t(string name, bit ok);
        if (ok) begin pass_cnt++; $display("PASS  %s", name); end
        else begin fail_cnt++; $display("FAIL  %s", name); end
    endtask

    initial begin
        #22 rst_n = 1;
        while (done_cyc < 0 && cycles < 5000) @(posedge clk);
        repeat (5) @(posedge clk);
        $display("core I$+MMU test (USE_ICACHE=%0d): signature at cycle %0d, traps=%0d, I$ refills=%0d (PA 0x5000 line: %0d), page-5 hits=%0d",
                 USE_ICACHE, done_cyc, traps, refills, refills_a, hits_a);
        chk("completion signature",                  mem['h3F0 >> 2], SIG);
        chk("satp readback (x20)",                   dut.regs[20], 32'h8000_0002);
        chk("code A ran 4x via VA 0x1000/0x6000 (x10)", dut.regs[10], 4);
        chk("code A (x11)",                          dut.regs[11], 32'hA2);
        chk("patched instr ran after FENCE.I (x12)", dut.regs[12], 32'h77);
        chk("decoys at untranslated PAs never ran",  dut.regs[29], 0);
        chk("fetch page faults taken (x24)",         dut.regs[24], 2);
        chk("traps total",                           traps, 2);
        for (int n = 0; n < 2; n++) begin
            chk($sformatf("PF%0d mcause", n), mem[('h300 + 12*n) >> 2],     12);
            chk($sformatf("PF%0d mtval",  n), mem[('h304 + 12*n) >> 2],     32'h4000);
            chk($sformatf("PF%0d mepc",   n), mem[('h308 + 12*n) >> 2],     32'h4000);
        end
        chk_t($sformatf("every ID instruction == mem[PA(pc)] (%0d errors)", contract_err), contract_err == 0);
        chk_t("faulting fetches reached ID as fault NOPs", fault_ids >= 2);
        if (USE_ICACHE) begin
            chk("I$ refills of non-mapped / untranslated PAs", refills_bad, 0);
            chk("PA 0x5000 line refills (cold + after FENCE.I)", refills_a, 2);
            chk_t($sformatf("later calls / VA alias hit the PA line (%0d hits)", hits_a), hits_a >= 8);
            chk_t("PA 0x5000 line was resident when FENCE.I committed", a_valid_at_fencei);
            chk_t("PA 0x5000 line refilled after FENCE.I", refill_a_after_fencei);
            begin
                bad_tag = 0;
                for (int l = 0; l < 8; l++)
                    if (dut.g_icache.u_icache.valid[l] &&
                        dut.g_icache.u_icache.tag[l][24:5] != 20'h0 &&
                    dut.g_icache.u_icache.tag[l][24:5] != 20'h5) bad_tag = 1;
                chk_t("no I$ line tagged with a fault / decoy page", !bad_tag);
            end
        end
        $display("SUMMARY: %0d PASS, %0d FAIL -> %s", pass_cnt, fail_cnt, fail_cnt == 0 ? "ALL PASS" : "FAILED");
        $finish;
    end
endmodule
