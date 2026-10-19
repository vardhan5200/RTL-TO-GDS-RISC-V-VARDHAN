// core_ifetch_tb.sv — Sv32 instruction-fetch translation and precise
// instruction page faults on core_top (USE_MMU=1, priv_mode=S from the tb
// port; the core itself is M-only and M-mode is never translated).
// Flat 32 KiB memory shared by fetch and data; program image
// tb/integration/core_ifetch_prog.hex (sparse, see gen_prog.py). The program:
//   * CSRW satp = 0x80000002, then calls VA 0x1000, which maps to PA 0x5000
//     (code A). PA 0x1000 holds different code (B) that must not run yet.
//   * jumps to VA 0x4000 (unmapped), VA 0x3000 (mapped RW, no X) and VA 0x5000
//     (invalid PTE although PA 0x5000 holds code): each gives mcause=12 with
//     mtval = mepc = target VA; the handler logs {mcause, mtval, mepc}, sets
//     mepc = ra and MRETs.
//   * runs code at VA 0x6FF8/0x6FFC (PA 0x7FF8) that falls into unmapped VA
//     0x7000: the two older instructions complete, then the fault is taken.
//   * calls VA 0x1FF8: a DIV (33-cycle stall) then a return. While the DIV
//     stalls, fetch translates the sequential VA 0x2000 (unmapped) and the
//     faulting fetch enters IF/ID, but the older return flushes it: no trap.
//   * CSRW satp = 0, calls VA 0x1000 again: Bare, so code B at PA 0x1000 runs.
`timescale 1ns/1ps
module core_ifetch_tb;
    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    logic [31:0] imem_addr, imem_rdata, dmem_addr, dmem_wdata, dmem_rdata;
    logic        dmem_re, dmem_we, mmu_fault;
    logic [3:0]  dmem_wstrb;
    logic [31:0] mem [0:8191];
    // pcs / return addresses printed by gen_prog.py
    localparam logic [31:0] RA_4000 = 32'h30, RA_3000 = 32'h3C, RA_5000 = 32'h48,
                            RA_6FF8 = 32'h58, RA_1FF8 = 32'h68;
    initial begin
        for (int k = 0; k < 8192; k++) mem[k] = 32'h0000_0013;   // NOPs everywhere
        for (int k = 32'h2000 >> 2; k < (32'h4000 >> 2); k++) mem[k] = 32'h0;  // page tables
        $readmemh("tb/integration/core_ifetch_prog.hex", mem);
        mem[32'h2000 >> 2] = 32'h0000_0C01;   // L1[0] -> L0 at PA 0x3000
        mem[32'h3000 >> 2] = 32'h0000_00CF;   // L0[0]: VA 0x0000 -> PA 0x0000, V|R|W|X|A|D
        mem[32'h3004 >> 2] = 32'h0000_14CB;   // L0[1]: VA 0x1000 -> PA 0x5000, V|R|X|A|D
        mem[32'h3008 >> 2] = 32'h0000_0000;   // L0[2]: invalid (wrong-path VA 0x2000)
        mem[32'h300C >> 2] = 32'h0000_18C7;   // L0[3]: VA 0x3000 -> PA 0x6000, V|R|W|A|D (no X)
        mem[32'h3010 >> 2] = 32'h0000_0000;   // L0[4]: invalid
        mem[32'h3014 >> 2] = 32'h0000_0000;   // L0[5]: invalid
        mem[32'h3018 >> 2] = 32'h0000_1CCB;   // L0[6]: VA 0x6000 -> PA 0x7000, V|R|X|A|D
        mem[32'h301C >> 2] = 32'h0000_0000;   // L0[7]: invalid
    end
    assign imem_rdata = mem[imem_addr[14:2]];
    assign dmem_rdata = mem[dmem_addr[14:2]];
    int oob = 0;
    always @(posedge clk)
        if (dmem_we) begin
            if (dmem_addr[31:15] != 0) oob++;
            for (int b = 0; b < 4; b++)
                if (dmem_wstrb[b]) mem[dmem_addr[14:2]][8*b +: 8] <= dmem_wdata[8*b +: 8];
        end

    core_top #(.CACHE_BASE(32'h0), .CACHE_LIMIT(32'h200), .USE_MMU(1'b1)) dut (
        .clk, .rst_n, .imem_addr, .imem_rdata,
        .dmem_re, .dmem_we, .dmem_addr, .dmem_wdata, .dmem_wstrb, .dmem_rdata,
        .meip(1'b0), .mtip(1'b0), .msip(1'b0),
        .priv_mode(2'b01), .mmu_fault);

    // monitors
    int ipte_reads = 0, fetch_pa5 = 0, fetch_pa1_xlate = 0, wrongpath_fault_id = 0, traps = 0;
    always @(posedge clk)
        if (rst_n) begin
            if (dut.iptw_req_valid && dut.iptw_req_ready) ipte_reads++;
            // accepted fetches (instruction enters IF/ID) by physical page
            if (!dut.stall && !dut.flush && dut.if_valid && !dut.if_fault) begin
                if (imem_addr[31:12] == 20'h5) fetch_pa5++;
                if (imem_addr[31:12] == 20'h1 && !dut.i_bare) fetch_pa1_xlate++;
            end
            if (dut.fault_id && dut.pc_id == 32'h2000) wrongpath_fault_id++;
            if (dut.p_trap) begin
                traps++;
                $display("  trap @pc %08h: mcause=%0d mtval=%08h -> %08h",
                         dut.pc_ex, dut.p_cause, dut.xcpt_tval_c, dut.p_redirect_pc);
            end
        end

    int errors = 0;
    task automatic chk(string name, logic [31:0] got, logic [31:0] exp);
        if (got !== exp) begin errors++; $display("  FAIL %-38s got %08h exp %08h", name, got, exp); end
        else                          $display("  ok   %-38s = %08h", name, got);
    endtask
    task automatic chk_trap(int n, string what, logic [31:0] va, logic [31:0] ra);
        logic [31:0] a; a = 32'h300 + 12 * n;
        chk($sformatf("%s mcause", what), mem[a >> 2],       32'd12);
        chk($sformatf("%s mtval",  what), mem[(a + 4) >> 2], va);
        chk($sformatf("%s mepc",   what), mem[(a + 8) >> 2], va);
        if (mem[a >> 2] === 32'd12 && mem[(a + 4) >> 2] === va && mem[(a + 8) >> 2] === va)
            $display("PASS: %s: mcause=12 mtval=0x%08h mepc=0x%08h, resumed at ra=0x%08h", what, va, va, ra);
    endtask
    int cyc = 0;
    initial begin
        #22 rst_n = 1;
        while (mem[32'h3F0 >> 2] !== 32'h1FE7_C00D && cyc < 5000) begin @(posedge clk); cyc++; end
        repeat (5) @(posedge clk);
        $display("core ifetch test: signature after %0d cycles", cyc);
        chk("satp readback (x20)",                 dut.regs[20], 32'h8000_0002);
        chk("code A ran once via VA 0x1000 (x10)", dut.regs[10], 32'hA1);
        chk("code A (x11)",                        dut.regs[11], 32'hA2);
        chk("fetches from PA page 0x5000",         fetch_pa5 >= 3, 1);
        chk("no translated fetch from PA 0x1000",  fetch_pa1_xlate, 0);
        chk_trap(0, "fetch PF unmapped VA 0x4000",  32'h4000, RA_4000);
        chk_trap(1, "fetch PF no-X VA 0x3000",      32'h3000, RA_3000);
        chk_trap(2, "fetch PF invalid VA 0x5000",   32'h5000, RA_5000);
        chk_trap(3, "fetch PF after 2 instrs VA 0x7000", 32'h7000, RA_6FF8);
        chk("no-X page code not run (x29)",        dut.regs[29], 32'h0);
        chk("older instr before PF ran (x12)",     dut.regs[12], 32'h5E);
        chk("older instr before PF ran (x13)",     dut.regs[13], 32'h1);
        chk("DIV on page end (x15 = 100/7)",       dut.regs[15], 32'd14);
        chk("wrong-path fault reached IF/ID",      wrongpath_fault_id > 0, 1);
        chk("traps taken: 4 (wrong path dropped)", traps, 4);
        chk("handler count (x24)",                 dut.regs[24], 32'd4);
        chk("execution resumed each time (x21)",   dut.regs[21], 32'd5);
        chk("satp = 0 again (x22)",                dut.regs[22], 32'h0);
        chk("Bare: PA 0x1000 code B ran (x23)",    dut.regs[23], 32'hB1);
        chk("I-side PTE reads happened",           ipte_reads > 0, 1);
        chk("mmu_fault (data side) not set",       mmu_fault, 0);
        chk("no out-of-range stores",              oob, 0);
        chk("completion signature",                mem[32'h3F0 >> 2], 32'h1FE7_C00D);
        $display("  (I-side PTE reads: %0d, fetches from PA page 5: %0d)", ipte_reads, fetch_pa5);
        if (errors == 0) $display("CORE IFETCH: PASS"); else $display("CORE IFETCH: FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
