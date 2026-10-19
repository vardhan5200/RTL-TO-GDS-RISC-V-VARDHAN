// core_satp_tb.sv — software-controlled MMU via the satp CSR (0x180).
// core_top USE_MMU=1, flat 32 KiB memory shared by fetch and data, priv_mode=S
// from the tb port (the core is M-only; M-mode is never translated). The
// program (gen_prog.py, core_satp_prog.hex):
//   1. satp reads 0 after reset; loads/stores are Bare (PA = VA): VA 0x1000
//      reads PA 0x1000, VA 0x4000 reads PA 0x4000 without a fault.
//   2. CSRW satp = 0x80000002 (Sv32, root PA 0x2000); read back; WARL check
//      (all-ones -> 0x803FFFFF), CSRRC/CSRRS; VA 0x1000 now maps to PA 0x5000,
//      a store goes to PA 0x5004 (not 0x1004), VA 0x4000 page-faults (13).
//   3. CSRW satp = 0x80000006 (root PA 0x6000): VA 0x1000 -> PA 0x4000; the
//      stale TLB entry (-> PA 0x5000) must have been flushed by the write.
//   4. CSRW satp = 0: Bare again.
// The tb also counts page-table reads: walks only happen while MODE=1.
`timescale 1ns/1ps
module core_satp_tb;
    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    logic [31:0] imem_addr, imem_rdata, dmem_addr, dmem_wdata, dmem_rdata;
    logic        dmem_re, dmem_we, mmu_fault;
    logic [3:0]  dmem_wstrb;
    logic [31:0] mem [0:8191];
    localparam logic [31:0] PC_PF = 32'h60;   // printed by gen_prog.py
    initial begin
        for (int k = 0; k < 8192; k++) mem[k] = 32'h0;
        $readmemh("tb/integration/core_satp_prog.hex", mem, 0, 127);
        mem[32'h1000 >> 2] = 32'h1111_1111;   // identity target
        mem[32'h1004 >> 2] = 32'h0;
        mem[32'h4000 >> 2] = 32'h4444_4444;
        mem[32'h5000 >> 2] = 32'h5555_5555;   // VA 0x1000 under root A
        mem[32'h5004 >> 2] = 32'h0;
        // root A (PA 0x2000): L1[0] -> L0 at PA 0x3000
        mem[32'h2000 >> 2] = 32'h0000_0C01;
        mem[32'h3004 >> 2] = 32'h0000_14C7;   // L0[1]: VA 0x1000 -> PPN 5, V|R|W|A|D
        mem[32'h3010 >> 2] = 32'h0000_0000;   // L0[4]: VA 0x4000 invalid
        // root B (PA 0x6000): L1[0] -> L0 at PA 0x7000
        mem[32'h6000 >> 2] = 32'h0000_1C01;
        mem[32'h7004 >> 2] = 32'h0000_10C7;   // L0[1]: VA 0x1000 -> PPN 4, V|R|W|A|D
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

    // page-table reads issued by the walker, and TLB flushes from satp writes
    int pte_reads = 0, satp_writes = 0;
    always @(posedge clk)
        if (rst_n) begin
            if (dut.ptw_req_valid && dut.ptw_req_ready) pte_reads++;
            if (dut.csr_satp_wr) begin
                satp_writes++;
                $display("  satp write: %08h -> MMU %s, TLB flushed", dut.u_priv.u_csr.wval & 32'h803F_FFFF,
                         (dut.u_priv.u_csr.wval[31]) ? "Sv32" : "Bare");
            end
            if (dut.p_trap)
                $display("  trap @pc %08h: mcause=%0d mtval=%08h", dut.pc_ex, dut.p_cause, dut.vaddr);
        end

    int errors = 0;
    task automatic chk(string name, logic [31:0] got, logic [31:0] exp);
        if (got !== exp) begin errors++; $display("  FAIL %-34s got %08h exp %08h", name, got, exp); end
        else                          $display("  ok   %-34s = %08h", name, got);
    endtask
    int cyc = 0;
    initial begin
        #22 rst_n = 1;
        while (mem[32'h3F0 >> 2] !== 32'h05A7_D00D && cyc < 3000) begin @(posedge clk); cyc++; end
        repeat (5) @(posedge clk);
        $display("core satp test: signature after %0d cycles", cyc);
        // phase 1: Bare
        chk("satp after reset (x6)",              dut.regs[6],  32'h0);
        chk("Bare lw VA 0x1000 -> PA 0x1000 (x7)", dut.regs[7],  32'h1111_1111);
        chk("Bare lw VA 0x4000, no fault (x8)",    dut.regs[8],  32'h4444_4444);
        chk("Bare sw VA 0x1004 -> PA 0x1004",      mem[32'h1004 >> 2], 32'hA1);
        // phase 2: Sv32 root A
        chk("csrr satp after csrw (x10)",          dut.regs[10], 32'h8000_0002);
        chk("csrrw old value (x12)",               dut.regs[12], 32'h8000_0002);
        chk("satp WARL all-ones (x13)",            dut.regs[13], 32'h803F_FFFF);
        chk("satp after csrrc all (x14)",          dut.regs[14], 32'h0);
        chk("Sv32 lw VA 0x1000 -> PA 0x5000 (x15)", dut.regs[15], 32'h5555_5555);
        chk("Sv32 sw VA 0x1004 -> PA 0x5004",      mem[32'h5004 >> 2], 32'hB2);
        chk("Sv32 lw VA 0x1004 (x16)",             dut.regs[16], 32'hB2);
        chk("page fault only when enabled: cause", dut.regs[25], 32'd13);
        chk("page fault mtval",                    dut.regs[26], 32'h4000);
        chk("page fault mepc",                     dut.regs[27], PC_PF + 4);
        chk("faulting lw rd untouched (x19)",      dut.regs[19], 32'h5A5);
        chk("instr after fault ran once (x17)",    dut.regs[17], 32'd1);
        // phase 3: new root, TLB flushed
        chk("root B lw VA 0x1000 -> PA 0x4000 (x18)", dut.regs[18], 32'h4444_4444);
        // phase 4: Bare again
        chk("csrr satp after csrw 0 (x20)",        dut.regs[20], 32'h0);
        chk("Bare again lw VA 0x1000 (x21)",       dut.regs[21], 32'h1111_1111);
        chk("Bare again lw VA 0x1004 (x22)",       dut.regs[22], 32'hA1);
        chk("Bare again lw VA 0x4000 (x23)",       dut.regs[23], 32'h4444_4444);
        // global
        chk("traps taken (x24)",                   dut.regs[24], 32'd1);
        chk("PTE reads (walks only when MODE=1)",  pte_reads,    32'd6);
        chk("satp writes (TLB flushes)",           satp_writes,  32'd6);
        chk("satp CSR final",                      dut.csr_satp, 32'h0);
        chk("PA 0x1004 untouched by Sv32 store",   mem[32'h1004 >> 2], 32'hA1);
        chk("no out-of-range stores",              oob,          32'd0);
        chk("completion signature",                mem[32'h3F0 >> 2], 32'h05A7_D00D);
        if (errors == 0) begin
            $display("PASS: satp=0 bypass, satp=0x80000002 translates VA 0x1000 -> PA 0x5000, satp=0 bypass again");
            $display("CORE SATP: PASS");
        end else $display("CORE SATP: FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
