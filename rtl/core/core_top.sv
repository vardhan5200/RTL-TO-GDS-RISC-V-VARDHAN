// core_top.sv — integrated RV32I(+MUL/DIV/DIVU/REM/REMU) core: pipeline_branch-style 3-stage
// pipeline (IF / ID / EX+MEM+WB) with
//   * L1 D-cache (rtl/cache/dm_cache.sv) for loads in [CACHE_BASE, CACHE_LIMIT);
//     stores are write-through (bus write + cache word update on hit, no
//     allocate). Other addresses (MMIO) bypass the cache.
//   * M-mode CSR/trap unit (rtl/priv/priv_unit.sv) at the commit point (EX):
//     CSR ops, ECALL/EBREAK/illegal traps, MRET, machine interrupts
//     (meip/mtip/msip inputs, e.g. meip from the SoC irq_ctrl).
//   * optional Sv32 MMUs (rtl/mmu/sv32_mmu.sv) on the data and fetch side, USE_MMU=1
//     (hardware present). satp comes from the satp CSR (0x180, csr_file):
//     software writes it with CSRW; MODE=0 -> Bare (PA = VA), MODE=1 -> Sv32
//     translation with the root table at PPN<<12. Every committed satp write
//     flushes both TLBs (no ASIDs; there is no SFENCE.VMA instruction yet).
//     Privilege modes M/S/U live in priv_unit (cur_priv, exported). The D-MMU
//     uses the effective data-access privilege: cur_priv, or mstatus.MPP when
//     cur_priv == M and mstatus.MPRV == 1. M is never translated; S/U are
//     translated when satp.MODE = Sv32, with the PTE U-bit check (U-mode only
//     U=1 pages; S-mode not U=1 pages unless mstatus.SUM) and mstatus.MXR.
//     priv_mode port (bring-up / test override, kept for older tests):
//     2'b11 -> use the architectural effective privilege for data accesses;
//     2'b00 / 2'b01 -> force U / S for data accesses regardless of cur_priv.
//     The I-MMU (fetch) is still driven by priv_mode only: 2'b11 -> Bare fetch;
//     2'b01 (S) -> satp decides.
//     With USE_MMU=0 satp is still a read/write CSR but has no effect.
//     MMU faults raise a precise synchronous
//     exception through priv_unit (xcpt_*): mcause = load/store page fault
//     13/15 (or access fault 5/7), mtval = faulting VA, mepc = pc of the
//     load/store. The access is squashed (no rd write, store never reaches the
//     bus/cache), younger instructions are flushed and fetch jumps to mtvec.
//     mmu_fault stays as a sticky status flag. (No I-side MMU, so instruction
//     page faults (12) cannot occur yet.)
//   * MUL (rtl/cpu/mul.sv) and DIV/DIVU/REM/REMU (rtl/cpu/div_unit.sv around
//     rtl/cpu/div.sv) in EX: one start pulse, IF/ID/EX stall until done, the
//     result is written back and forwarded to ID on the done cycle.
//     DIV latency: 33 cycles in EX (32 iterations + start), i.e. 32 stall cycles.
// Instruction side: imem is read combinationally (no I-cache in this branch).
// With USE_MMU=1 fetch is translated by a second sv32_mmu instance (I-MMU,
// own 4-entry I-TLB, req_acc=fetch) whenever satp.MODE=1 and priv_mode is not
// M (same rule as the data side). A 1-entry fetch translation register (last
// VPN -> PPN / fault) lets sequential fetches in a page run at 1 IPC; on a miss
// the PC holds, a bubble enters ID and the I-MMU translates (TLB hit: 1 cycle,
// miss: two-level walk on the shared data bus). Bare (MODE=0 or M-mode):
// imem_addr = pc, exactly as without the MMU. A fetch fault (12 page fault /
// 1 access fault) is carried with the instruction (fault_id/fault_ex, as a
// NOP) and raised through priv_unit's xcpt_* port only when it reaches EX, so
// older instructions complete first and wrong-path fetch faults are flushed
// with the instruction. mtval = mepc = faulting virtual PC. The fetch
// translation register is cleared on satp writes and on every trap/mret.
// A satp write also flushes both TLBs and the pipeline (refetch at pc+4 under
// the new translation).
// Data-bus arbitration with the I-side walker: the data side (older
// instruction) wins; the I-MMU only starts a translation when no load/store is
// in EX, and a load/store waits in EX while an I-translation is in flight.
// Data bus: one combinational-read port shared by the cache refill, the MMU
// walker and uncached/stores (all serialized by EX stalls).
`timescale 1ns/1ps

module core_top #(
    parameter logic [31:0] CACHE_BASE  = 32'h0000_0000,
    parameter logic [31:0] CACHE_LIMIT = 32'h0000_0200,
    parameter bit          USE_MMU     = 1'b0
) (
    input  logic        clk, rst_n,
    output logic [31:0] imem_addr,
    input  logic [31:0] imem_rdata,
    output logic        dmem_re,
    output logic        dmem_we,
    output logic [31:0] dmem_addr,
    output logic [31:0] dmem_wdata,
    output logic [3:0]  dmem_wstrb,
    input  logic [31:0] dmem_rdata,
    input  logic        meip, mtip, msip,
    input  logic [1:0]  priv_mode,     // 2'b11 = architectural; U/S = forced MMU privilege
    output logic        mmu_fault,
    output logic [1:0]  cur_priv       // current privilege mode (00 U, 01 S, 11 M)
);
    localparam logic [31:0] NOP = 32'h0000_0013;

    logic        stall, flush, retire;
    logic [31:0] pc, next_pc, redirect_pc;
    // Forward declarations: used in IF, driven further down.
    logic        p_redirect;   // priv_unit trap / mret redirect
    logic [31:0] csr_satp;     // satp CSR -> MMUs
    logic        csr_satp_wr;  // satp write committed -> TLB flushes, pipeline flush
    logic        lsu_busy;     // data side translation / access in progress
    logic        mem_op;       // load/store in EX

    // ---------------- IF (optional Sv32 fetch translation) ----------------
    logic        if_valid;     // instruction (or fetch fault) available for pc
    logic [31:0] if_instr;
    logic        if_fault;     // fetch fault for pc
    logic [3:0]  if_fcause;    // 12 page fault / 1 access fault
    logic        i_bare;       // fetch untranslated (PA = VA)
    logic        ifx_valid, ifx_fault, ifx_hit;   // fetch translation register
    logic [19:0] ifx_vpn;
    logic [21:0] ifx_ppn;
    logic [3:0]  ifx_cause;
    logic [33:0] if_paddr;

    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n)                             pc <= 32'h0;
        else if (!stall && (if_valid || flush)) pc <= next_pc;

    assign i_bare    = !USE_MMU || !csr_satp[31] || (priv_mode == 2'b11);
    assign ifx_hit   = ifx_valid && (ifx_vpn == pc[31:12]);
    assign if_paddr  = {ifx_ppn, pc[11:0]};
    assign imem_addr = i_bare ? pc : if_paddr[31:0];
    assign if_valid  = i_bare || ifx_hit;
    assign if_fault  = !i_bare && ifx_hit && ifx_fault;
    assign if_fcause = ifx_cause;
    assign if_instr  = if_fault ? NOP : imem_rdata;

    logic [31:0] instr_id, pc_id;
    logic        bubble_id, fault_id;
    logic [3:0]  fcause_id;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            instr_id <= NOP; pc_id <= 32'h0; bubble_id <= 1; fault_id <= 0; fcause_id <= 4'd0;
        end else if (flush) begin   // synchronous squash (kept out of the async reset term)
            instr_id <= NOP; pc_id <= 32'h0; bubble_id <= 1; fault_id <= 0; fcause_id <= 4'd0;
        end else if (!stall && if_valid) begin
            instr_id <= if_instr; pc_id <= pc; bubble_id <= 0;
            fault_id <= if_fault; fcause_id <= if_fcause;
        end else if (!stall) begin   // fetch translation pending: bubble
            instr_id <= NOP; pc_id <= pc; bubble_id <= 1; fault_id <= 0; fcause_id <= 4'd0;
        end
    end

    // ---------------- ID ----------------
    logic [4:0] rd_id, rs1_id, rs2_id;
    logic [2:0] funct3_id;
    logic [6:0] opcode_id;
    assign opcode_id = instr_id[6:0];
    assign rd_id     = instr_id[11:7];
    assign funct3_id = instr_id[14:12];
    assign rs1_id    = instr_id[19:15];
    assign rs2_id    = instr_id[24:20];

    logic illegal_id, alu_src_b_id, mem_read_id, mem_write_id, mem_unsigned_id;
    logic reg_write_id, branch_id, jump_id, jalr_id;
    logic [3:0] alu_op_id;
    logic [2:0] imm_sel_id, mem_size_id;
    logic [1:0] wb_sel_id;
    decoder u_dec (.instr(instr_id), .illegal(illegal_id), .alu_op(alu_op_id),
                   .imm_sel(imm_sel_id), .alu_src_b(alu_src_b_id),
                   .mem_read(mem_read_id), .mem_write(mem_write_id),
                   .mem_size(mem_size_id), .mem_unsigned(mem_unsigned_id),
                   .reg_write(reg_write_id), .wb_sel(wb_sel_id),
                   .branch(branch_id), .jump(jump_id), .jalr(jalr_id));

    logic [31:0] imm_id;
    imm_gen u_imm (.instr(instr_id), .imm_sel(imm_sel_id), .imm(imm_id));

    logic is_mul_id, is_div_id, ok_id, valid_id;
    assign is_mul_id = (opcode_id == 7'b0110011) && (instr_id[31:25] == 7'h01) &&
                       (funct3_id == 3'b000);
    // DIV/DIVU/REM/REMU: funct7=0000001, funct3=1xx
    assign is_div_id = (opcode_id == 7'b0110011) && (instr_id[31:25] == 7'h01) &&
                       funct3_id[2];
    // Every real instruction goes to EX; priv_unit traps illegal ones there.
    assign valid_id = !bubble_id;
    assign ok_id    = !illegal_id || is_mul_id || is_div_id;   // side effects allowed

    logic [31:0] regs [0:31];
    logic        ex_wen;
    logic [4:0]  rd_ex;
    logic [31:0] ex_result, rd1_id, rd2_id;
    always_comb begin
        if (rs1_id == 0)                       rd1_id = 32'h0;
        else if (ex_wen && rd_ex == rs1_id)    rd1_id = ex_result;
        else                                   rd1_id = regs[rs1_id];
        if (rs2_id == 0)                       rd2_id = 32'h0;
        else if (ex_wen && rd_ex == rs2_id)    rd2_id = ex_result;
        else                                   rd2_id = regs[rs2_id];
    end

    // ---------------- ID/EX ----------------
    logic        valid_ex, reg_write_ex, alu_src_b_ex, branch_ex, jump_ex, jalr_ex, is_mul_ex, is_div_ex;
    logic        mem_read_ex, mem_write_ex, fault_ex;
    logic [3:0]  fcause_ex;
    logic [31:0] pc_ex, rd1_ex, rd2_ex, imm_ex, instr_ex;
    logic [3:0]  alu_op_ex;
    logic [2:0]  funct3_ex;
    logic [6:0]  opcode_ex;
    logic [1:0]  wb_sel_ex;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_ex <= 0; reg_write_ex <= 0; alu_src_b_ex <= 0;
            branch_ex <= 0; jump_ex <= 0; jalr_ex <= 0; is_mul_ex <= 0; is_div_ex <= 0;
            mem_read_ex <= 0; mem_write_ex <= 0; instr_ex <= NOP;
            fault_ex <= 0; fcause_ex <= 4'd0;
            pc_ex <= 0; rd1_ex <= 0; rd2_ex <= 0; imm_ex <= 0;
            alu_op_ex <= 0; funct3_ex <= 0; opcode_ex <= 0; wb_sel_ex <= 0; rd_ex <= 0;
        end else if (flush) begin   // synchronous bubble
            valid_ex <= 0; reg_write_ex <= 0; alu_src_b_ex <= 0;
            branch_ex <= 0; jump_ex <= 0; jalr_ex <= 0; is_mul_ex <= 0; is_div_ex <= 0;
            mem_read_ex <= 0; mem_write_ex <= 0; instr_ex <= NOP;
            fault_ex <= 0; fcause_ex <= 4'd0;
            pc_ex <= 0; rd1_ex <= 0; rd2_ex <= 0; imm_ex <= 0;
            alu_op_ex <= 0; funct3_ex <= 0; opcode_ex <= 0; wb_sel_ex <= 0; rd_ex <= 0;
        end else if (!stall) begin
            valid_ex     <= valid_id;
            reg_write_ex <= (reg_write_id || is_mul_id || is_div_id) && ok_id && valid_id;
            alu_src_b_ex <= alu_src_b_id;
            branch_ex    <= branch_id && ok_id && valid_id;
            jump_ex      <= jump_id && ok_id && valid_id;
            jalr_ex      <= jalr_id && ok_id && valid_id;
            is_mul_ex    <= is_mul_id && valid_id;
            is_div_ex    <= is_div_id && valid_id;
            mem_read_ex  <= mem_read_id && ok_id && valid_id;
            mem_write_ex <= mem_write_id && ok_id && valid_id;
            instr_ex     <= instr_id;
            fault_ex     <= fault_id && valid_id;
            fcause_ex    <= fcause_id;
            pc_ex <= pc_id; rd1_ex <= rd1_id; rd2_ex <= rd2_id; imm_ex <= imm_id;
            alu_op_ex <= alu_op_id; funct3_ex <= funct3_id; opcode_ex <= opcode_id;
            wb_sel_ex <= wb_sel_id; rd_ex <= rd_id;
        end
    end

    // ---------------- EX ----------------
    logic [31:0] alu_a, alu_b, alu_y;
    logic        alu_zero;
    always_comb begin
        if (opcode_ex == 7'b0110111)      alu_a = 32'h0;   // LUI
        else if (opcode_ex == 7'b0010111) alu_a = pc_ex;   // AUIPC
        else                              alu_a = rd1_ex;
        alu_b = alu_src_b_ex ? imm_ex : rd2_ex;
    end
    alu u_alu (.a(alu_a), .b(alu_b), .op(alu_op_ex), .y(alu_y), .zero(alu_zero));

    logic        bu_taken;
    logic [31:0] bu_target;
    branch_unit u_bu (.rs1(rd1_ex), .rs2(rd2_ex), .funct3(funct3_ex),
                      .branch(branch_ex), .jump(jump_ex && !jalr_ex),
                      .pc(pc_ex), .imm(imm_ex), .taken(bu_taken), .target(bu_target));

    // ---- privileged unit at the commit point ----
    logic        mul_wait, div_wait, ex_first;
    logic        p_rd_we, p_trap, p_irq, p_mret;
    logic [31:0] p_rd_wdata, p_redirect_pc, p_cause;
    logic        mmu_xcpt;     // MMU fault on the EX load/store (defined in the LSU)
    // Declared here (before priv_unit uses them); driven in the LSU section below.
    logic [31:0] vaddr;        // load/store virtual address
    logic [3:0]  mmu_cause;    // MMU fault cause (12/13/15, 1/5/7)
    logic [31:0] mmu_xcpt_cause;
    assign mmu_xcpt_cause = {28'b0, mmu_cause};
    logic [1:0]  st_mpp;       // mstatus fields for the MMU
    logic        st_mprv, st_sum, st_mxr;
    // Present each instruction once, on its first EX cycle (before any
    // multi-cycle MUL / DIV / load starts), so a trap can cleanly squash it.
    assign ex_first = valid_ex && !mul_wait && !div_wait && !lsu_busy;
    // Synchronous exception into priv_unit: a fetch fault carried with the
    // instruction now in EX, or a data-side MMU fault of the load/store in EX.
    // Both belong to the instruction in EX (the oldest), and they cannot both
    // be set (a fetch-faulted instruction is a NOP with no memory access);
    // the fetch fault is listed first because it is detected first.
    logic        if_xcpt, xcpt_any;
    logic [31:0] xcpt_cause_c, xcpt_tval_c;
    assign if_xcpt      = ex_first && fault_ex;
    assign xcpt_any     = if_xcpt || mmu_xcpt;
    assign xcpt_cause_c = if_xcpt ? {28'b0, fcause_ex} : mmu_xcpt_cause;
    assign xcpt_tval_c  = if_xcpt ? pc_ex : vaddr;
    priv_unit u_priv (
        .clk, .rst_n,
        .instr_valid(ex_first),
        .instr((is_mul_ex || is_div_ex) ? NOP : instr_ex),   // decoder doesn't know M ops
        .pc(pc_ex), .rs1_data(rd1_ex),
        .mtip, .msip, .meip,
        .xcpt_valid(xcpt_any), .xcpt_cause(xcpt_cause_c), .xcpt_tval(xcpt_tval_c),
        .rd_we(p_rd_we), .rd_wdata(p_rd_wdata),
        .redirect(p_redirect), .redirect_pc(p_redirect_pc),
        .trap(p_trap), .irq_taken(p_irq), .mret(p_mret), .cause_o(p_cause),
        .satp_o(csr_satp), .satp_wr_o(csr_satp_wr),
        .cur_priv(cur_priv), .mstatus_mpp(st_mpp), .mstatus_mprv(st_mprv),
        .mstatus_sum(st_sum), .mstatus_mxr(st_mxr));

    // Effective privilege for data accesses (MPRV: loads/stores use MPP in M)
    logic [1:0] eff_priv, mmu_priv;
    assign eff_priv = (cur_priv == 2'b11 && st_mprv) ? st_mpp : cur_priv;
    assign mmu_priv = (priv_mode != 2'b11) ? priv_mode : eff_priv;

    logic br_flush, satp_flush;
    assign br_flush    = valid_ex && !p_trap && (bu_taken || jalr_ex);
    // satp write: refetch the following instructions under the new translation
    assign satp_flush  = USE_MMU && csr_satp_wr && !p_trap;
    assign flush       = p_redirect || br_flush || satp_flush;
    assign redirect_pc = p_redirect ? p_redirect_pc :
                         satp_flush ? (pc_ex + 32'd4) :
                         jalr_ex    ? ((rd1_ex + imm_ex) & ~32'h1) : bu_target;
    assign next_pc     = flush ? redirect_pc : pc + 32'd4;

    // ---- multiplier ----
    logic mul_start, mul_done;
    logic [31:0] mul_result;
    assign mul_start = valid_ex && is_mul_ex && !mul_wait && !p_trap;
    mul u_mul (.clk, .rst_n, .start(mul_start), .a(rd1_ex), .b(rd2_ex),
               .result(mul_result), .done(mul_done));
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n)         mul_wait <= 0;
        else if (mul_start) mul_wait <= 1;
        else if (mul_done)  mul_wait <= 0;

    // ---- divider (DIV/DIVU/REM/REMU), same handshake as the multiplier ----
    logic div_start, div_done;
    logic [31:0] div_result;
    assign div_start = valid_ex && is_div_ex && !div_wait && !p_trap;
    div_unit u_div (.clk, .rst_n, .start(div_start), .op(funct3_ex[1:0]),
                    .a(rd1_ex), .b(rd2_ex), .result(div_result), .done(div_done));
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n)         div_wait <= 0;
        else if (div_start) div_wait <= 1;
        else if (div_done)  div_wait <= 0;

    // ---- load/store unit (optional MMU -> D-cache / uncached bus) ----
    localparam logic [1:0] L_IDLE = 2'd0, L_XLATE = 2'd1, L_ACC = 2'd2, L_CWAIT = 2'd3;
    logic [1:0]  lsu_st;
    logic [31:0] paddr, paddr_q, load_word, load_data, st_wdata;
    logic [3:0]  st_strb;
    logic        lsu_go, lsu_done, cacheable, acc_now;
    assign lsu_busy = (lsu_st != L_IDLE);
    assign mem_op   = valid_ex && (mem_read_ex || mem_write_ex) && !p_trap;
    assign vaddr    = alu_y;     // ID/EX is held while the LSU is busy -> stable

    // MMU
    logic        mmu_req_valid, mmu_req_ready, mmu_resp_valid, mmu_pf, mmu_af;
    logic [33:0] mmu_paddr;
    logic        ptw_req_valid, ptw_req_ready, ptw_resp_valid, ptw_resp_ready;
    logic [33:0] ptw_addr;
    logic        ptw_pend;     // PTW read outstanding on the shared bus
    logic [31:0] ptw_addr_q;

    // I-side MMU (fetch translation)
    logic        immu_req_valid, immu_req_ready, immu_resp_valid, immu_pf, immu_af;
    logic [33:0] immu_paddr;
    logic [3:0]  immu_cause;
    logic        iptw_req_valid, iptw_req_ready, iptw_resp_valid, iptw_resp_ready;
    logic [33:0] iptw_addr;
    logic        iptw_pend;    // I-PTW read outstanding on the shared bus
    logic [31:0] iptw_addr_q;
    logic        i_inflight;   // I-MMU request accepted, response not yet seen
    logic        i_drop;       // discard the in-flight response (satp write / trap / mret)
    logic        i_inval;      // clear the fetch translation register now
    logic [19:0] i_vpn_q;      // VPN of the in-flight fetch translation

    // D-cache
    logic        dc_req_valid, dc_req_ready, dc_resp_valid, dc_mem_re;
    logic [31:0] dc_resp_rdata, dc_mem_addr;

    assign paddr     = (lsu_st == L_ACC) ? paddr_q : vaddr;
    assign cacheable = (paddr >= CACHE_BASE) && (paddr < CACHE_LIMIT);
    // access happens now: IDLE (no MMU) or ACC (after translation)
    assign acc_now   = mem_op && ((!USE_MMU && lsu_st == L_IDLE) || lsu_st == L_ACC);

    always @(*) begin
        case (funct3_ex[1:0])
            2'd0:    begin st_strb = 4'b0001 << paddr[1:0]; st_wdata = {4{rd2_ex[7:0]}}; end
            2'd1:    begin st_strb = 4'b0011 << {paddr[1], 1'b0}; st_wdata = {2{rd2_ex[15:0]}}; end
            default: begin st_strb = 4'b1111; st_wdata = rd2_ex; end
        endcase
    end

    logic st_now, ld_unc_now, ld_c_issue;
    assign st_now     = acc_now && mem_write_ex;
    assign ld_unc_now = acc_now && mem_read_ex && !cacheable;
    assign ld_c_issue = acc_now && mem_read_ex && cacheable;
    assign dc_req_valid = ld_c_issue;
    // data side waits while a fetch translation is in flight (shared PTE bus)
    assign mmu_req_valid = USE_MMU && mem_op && lsu_st == L_IDLE && !i_inflight;

    // ---- fetch translation register / I-MMU request ----
    assign i_inval = csr_satp_wr || p_redirect;
    // Start a fetch translation only when no load/store is in EX (the older
    // data access has priority on the shared bus) and fetch is not being
    // redirected this cycle.
    assign immu_req_valid = USE_MMU && !i_bare && !ifx_hit && !i_inflight &&
                            !mem_op && !lsu_busy && !flush && !i_inval;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            i_inflight <= 1'b0; i_drop <= 1'b0; i_vpn_q <= 20'b0;
            ifx_valid <= 1'b0; ifx_vpn <= 20'b0; ifx_ppn <= 22'b0;
            ifx_fault <= 1'b0; ifx_cause <= 4'd0;
        end else begin
            if (immu_req_valid && immu_req_ready) begin
                i_inflight <= 1'b1; i_drop <= 1'b0; i_vpn_q <= pc[31:12];
            end else if (i_inflight && immu_resp_valid) begin   // resp_ready = 1
                i_inflight <= 1'b0;
                if (!i_drop && !i_inval) begin
                    ifx_valid <= 1'b1;            ifx_vpn   <= i_vpn_q;
                    ifx_ppn   <= immu_paddr[33:12];
                    ifx_fault <= immu_pf || immu_af; ifx_cause <= immu_cause;
                end
            end else if (i_inflight && i_inval) begin
                i_drop <= 1'b1;
            end
            if (i_inval) ifx_valid <= 1'b0;
        end
    end

    always_comb begin
        lsu_done  = 1'b0;
        load_word = dmem_rdata;
        if (st_now || ld_unc_now) lsu_done = 1'b1;
        if (lsu_st == L_CWAIT && dc_resp_valid) begin lsu_done = 1'b1; load_word = dc_resp_rdata; end
        if (mmu_xcpt) lsu_done = 1'b1; // squashed, trap taken
    end
    // Translation fault -> precise exception (cause from the MMU's access type)
    assign mmu_xcpt = USE_MMU && valid_ex && (mem_read_ex || mem_write_ex) &&
                      (lsu_st == L_XLATE) && mmu_resp_valid && (mmu_pf || mmu_af);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin lsu_st <= L_IDLE; paddr_q <= 0; mmu_fault <= 0; end
        else case (lsu_st)
            L_IDLE:  if (mmu_req_valid && mmu_req_ready) lsu_st <= L_XLATE;
                     else if (ld_c_issue && dc_req_ready) lsu_st <= L_CWAIT;
            L_XLATE: if (mmu_resp_valid) begin
                         paddr_q <= mmu_paddr[31:0];
                         if (mmu_pf || mmu_af) begin mmu_fault <= 1; lsu_st <= L_IDLE; end
                         else lsu_st <= L_ACC;
                     end
            L_ACC:   if (ld_c_issue && dc_req_ready) lsu_st <= L_CWAIT;
                     else if (lsu_done) lsu_st <= L_IDLE;
            L_CWAIT: if (dc_resp_valid) lsu_st <= L_IDLE;
        endcase
    end

    logic [31:0] sh;
    always @(*) begin
        sh = load_word >> (8 * paddr[1:0]);
        case (funct3_ex)
            3'd0: load_data = {{24{sh[7]}}, sh[7:0]};
            3'd1: load_data = {{16{sh[15]}}, sh[15:0]};
            3'd4: load_data = {24'b0, sh[7:0]};
            3'd5: load_data = {16'b0, sh[15:0]};
            default: load_data = load_word;
        endcase
    end

    dm_cache u_dcache (
        .clk, .rst_n,
        .req_valid(dc_req_valid), .req_ready(dc_req_ready), .req_addr(paddr),
        .resp_valid(dc_resp_valid), .resp_rdata(dc_resp_rdata),
        .mem_re(dc_mem_re), .mem_addr(dc_mem_addr), .mem_rdata(dmem_rdata),
        .wr_en(st_now && cacheable), .wr_addr(paddr), .wr_wdata(st_wdata), .wr_strb(st_strb));

    generate if (USE_MMU) begin : g_mmu
        sv32_mmu #(.TLB_ENTRIES(4)) u_mmu (
            .clk, .rst_n,
            .satp(csr_satp), .priv(mmu_priv), .sum(st_sum), .mxr(st_mxr), .flush(csr_satp_wr),
            .req_valid(mmu_req_valid), .req_ready(mmu_req_ready),
            .req_vaddr(vaddr), .req_acc(mem_write_ex ? 2'd1 : 2'd0),
            .resp_valid(mmu_resp_valid), .resp_ready(lsu_st == L_XLATE),
            .resp_paddr(mmu_paddr), .resp_page_fault(mmu_pf),
            .resp_access_fault(mmu_af), .resp_cause(mmu_cause),
            .mem_req_valid(ptw_req_valid), .mem_req_ready(ptw_req_ready),
            .mem_req_addr(ptw_addr), .mem_resp_valid(ptw_resp_valid),
            .mem_resp_ready(ptw_resp_ready), .mem_resp_rdata(dmem_rdata),
            .mem_resp_error(1'b0));
        // PTE reads on the shared bus: accept a request, return data next cycle
        always_ff @(posedge clk or negedge rst_n)
            if (!rst_n) begin ptw_pend <= 0; ptw_addr_q <= 0; end
            else if (ptw_req_valid && ptw_req_ready) begin ptw_pend <= 1; ptw_addr_q <= ptw_addr[31:0]; end
            else if (ptw_resp_valid && ptw_resp_ready) ptw_pend <= 0;
        assign ptw_req_ready  = !ptw_pend && !iptw_pend;
        assign ptw_resp_valid = ptw_pend;

        // I-MMU: fetch translation, own I-TLB, PTE reads on the same bus
        sv32_mmu #(.TLB_ENTRIES(4)) u_immu (
            .clk, .rst_n,
            .satp(csr_satp), .priv(priv_mode), .sum(1'b0), .mxr(1'b0), .flush(csr_satp_wr),
            .req_valid(immu_req_valid), .req_ready(immu_req_ready),
            .req_vaddr(pc), .req_acc(2'd2),
            .resp_valid(immu_resp_valid), .resp_ready(1'b1),
            .resp_paddr(immu_paddr), .resp_page_fault(immu_pf),
            .resp_access_fault(immu_af), .resp_cause(immu_cause),
            .mem_req_valid(iptw_req_valid), .mem_req_ready(iptw_req_ready),
            .mem_req_addr(iptw_addr), .mem_resp_valid(iptw_resp_valid),
            .mem_resp_ready(iptw_resp_ready), .mem_resp_rdata(dmem_rdata),
            .mem_resp_error(1'b0));
        always_ff @(posedge clk or negedge rst_n)
            if (!rst_n) begin iptw_pend <= 0; iptw_addr_q <= 0; end
            else if (iptw_req_valid && iptw_req_ready) begin iptw_pend <= 1; iptw_addr_q <= iptw_addr[31:0]; end
            else if (iptw_resp_valid && iptw_resp_ready) iptw_pend <= 0;
        // bus free: no data-side walk / refill / access in progress
        assign iptw_req_ready  = !iptw_pend && !ptw_pend && !dc_mem_re && !lsu_busy;
        assign iptw_resp_valid = iptw_pend;
    end else begin : g_nommu
        assign mmu_req_ready = 1'b0; assign mmu_resp_valid = 1'b0;
        assign mmu_paddr = '0; assign mmu_pf = 1'b0; assign mmu_af = 1'b0; assign mmu_cause = '0;
        assign ptw_req_valid = 1'b0; assign ptw_addr = '0; assign ptw_resp_ready = 1'b0;
        assign ptw_req_ready = 1'b0; assign ptw_resp_valid = 1'b0;
        assign ptw_pend = 1'b0; assign ptw_addr_q = '0;
        assign immu_req_ready = 1'b0; assign immu_resp_valid = 1'b0;
        assign immu_paddr = '0; assign immu_pf = 1'b0; assign immu_af = 1'b0; assign immu_cause = '0;
        assign iptw_req_valid = 1'b0; assign iptw_addr = '0; assign iptw_resp_ready = 1'b0;
        assign iptw_req_ready = 1'b0; assign iptw_resp_valid = 1'b0;
        assign iptw_pend = 1'b0; assign iptw_addr_q = '0;
    end endgenerate

    // ---- shared data bus mux: cache refill > PTW > core access ----
    always_comb begin
        dmem_re = 1'b0; dmem_we = 1'b0; dmem_addr = paddr; dmem_wdata = st_wdata; dmem_wstrb = 4'b0;
        if (dc_mem_re) begin
            dmem_re = 1'b1; dmem_addr = dc_mem_addr;
        end else if (ptw_pend) begin
            dmem_re = 1'b1; dmem_addr = ptw_addr_q;
        end else if (iptw_pend) begin
            dmem_re = 1'b1; dmem_addr = iptw_addr_q;
        end else if (st_now) begin
            dmem_we = 1'b1; dmem_wstrb = st_strb;
        end else if (ld_unc_now) begin
            dmem_re = 1'b1;
        end
    end

    // ---- stall / writeback ----
    assign stall = !p_trap && ((valid_ex && is_mul_ex && !mul_done) ||
                               (valid_ex && is_div_ex && !div_done) || (mem_op && !lsu_done));

    always_comb begin
        if (is_mul_ex)            ex_result = mul_result;
        else if (is_div_ex)       ex_result = div_result;
        else if (mem_read_ex)     ex_result = load_data;
        else if (p_rd_we)         ex_result = p_rd_wdata;
        else if (wb_sel_ex == 2)  ex_result = pc_ex + 32'd4;
        else                      ex_result = alu_y;
    end

    logic squash_ld;
    assign squash_ld = mmu_xcpt;
    assign ex_wen = valid_ex && !stall && !p_trap && !squash_ld && (rd_ex != 0) &&
                    (reg_write_ex || p_rd_we);
    assign retire = valid_ex && !stall && !p_trap;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < 32; i++) regs[i] <= 32'h0;
        end else if (ex_wen) begin
            regs[rd_ex] <= ex_result;
        end
    end
endmodule
