// core_top.sv — integrated RV32I(+MUL) core: pipeline_branch-style 3-stage
// pipeline (IF / ID / EX+MEM+WB) with
//   * L1 D-cache (rtl/cache/dm_cache.sv) for loads in [CACHE_BASE, CACHE_LIMIT);
//     stores are write-through (bus write + cache word update on hit, no
//     allocate). Other addresses (MMIO) bypass the cache.
//   * M-mode CSR/trap unit (rtl/priv/priv_unit.sv) at the commit point (EX):
//     CSR ops, ECALL/EBREAK/illegal traps, MRET, machine interrupts
//     (meip/mtip/msip inputs, e.g. meip from the SoC irq_ctrl).
//   * optional Sv32 MMU (rtl/mmu/sv32_mmu.sv) on the data side, USE_MMU=1.
//     satp/priv come from ports (csr_file has no satp / S/U modes yet), so in
//     M-mode the MMU is a passthrough. MMU faults are NOT yet routed into
//     priv_unit (it has no external-exception input); they squash the access
//     and raise mmu_fault.
// The instruction side fetches combinationally from imem (no I-cache / I-MMU).
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
    input  logic [31:0] satp,          // MMU only (tie 0)
    input  logic [1:0]  priv_mode,     // MMU only (tie 2'b11)
    output logic        mmu_fault
);
    localparam logic [31:0] NOP = 32'h0000_0013;

    logic        stall, flush, retire;
    logic [31:0] pc, next_pc, redirect_pc;

    // ---------------- IF ----------------
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n)      pc <= 32'h0;
        else if (!stall) pc <= next_pc;
    assign imem_addr = pc;

    logic [31:0] instr_id, pc_id;
    logic        bubble_id;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)      begin instr_id <= NOP; pc_id <= 32'h0; bubble_id <= 1; end
        else if (flush)  begin instr_id <= NOP; pc_id <= 32'h0; bubble_id <= 1; end
        else if (!stall) begin instr_id <= imem_rdata; pc_id <= pc; bubble_id <= 0; end
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

    logic is_mul_id, ok_id, valid_id;
    assign is_mul_id = (opcode_id == 7'b0110011) && (instr_id[31:25] == 7'h01) &&
                       (funct3_id == 3'b000);
    // Every real instruction goes to EX; priv_unit traps illegal ones there.
    assign valid_id = !bubble_id;
    assign ok_id    = !illegal_id || is_mul_id;   // side effects allowed

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
    logic        valid_ex, reg_write_ex, alu_src_b_ex, branch_ex, jump_ex, jalr_ex, is_mul_ex;
    logic        mem_read_ex, mem_write_ex;
    logic [31:0] pc_ex, rd1_ex, rd2_ex, imm_ex, instr_ex;
    logic [3:0]  alu_op_ex;
    logic [2:0]  funct3_ex;
    logic [6:0]  opcode_ex;
    logic [1:0]  wb_sel_ex;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n || flush) begin
            valid_ex <= 0; reg_write_ex <= 0; alu_src_b_ex <= 0;
            branch_ex <= 0; jump_ex <= 0; jalr_ex <= 0; is_mul_ex <= 0;
            mem_read_ex <= 0; mem_write_ex <= 0; instr_ex <= NOP;
            pc_ex <= 0; rd1_ex <= 0; rd2_ex <= 0; imm_ex <= 0;
            alu_op_ex <= 0; funct3_ex <= 0; opcode_ex <= 0; wb_sel_ex <= 0; rd_ex <= 0;
        end else if (!stall) begin
            valid_ex     <= valid_id;
            reg_write_ex <= (reg_write_id || is_mul_id) && ok_id && valid_id;
            alu_src_b_ex <= alu_src_b_id;
            branch_ex    <= branch_id && ok_id && valid_id;
            jump_ex      <= jump_id && ok_id && valid_id;
            jalr_ex      <= jalr_id && ok_id && valid_id;
            is_mul_ex    <= is_mul_id && valid_id;
            mem_read_ex  <= mem_read_id && ok_id && valid_id;
            mem_write_ex <= mem_write_id && ok_id && valid_id;
            instr_ex     <= instr_id;
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
    logic        mul_wait, lsu_busy, ex_first;
    logic        p_rd_we, p_redirect, p_trap, p_irq, p_mret;
    logic [31:0] p_rd_wdata, p_redirect_pc, p_cause;
    // Present each instruction once, on its first EX cycle (before any
    // multi-cycle MUL / load starts), so a trap can cleanly squash it.
    assign ex_first = valid_ex && !mul_wait && !lsu_busy;
    priv_unit u_priv (
        .clk, .rst_n,
        .instr_valid(ex_first),
        .instr(is_mul_ex ? NOP : instr_ex),   // decoder doesn't know MUL
        .pc(pc_ex), .rs1_data(rd1_ex),
        .mtip, .msip, .meip,
        .rd_we(p_rd_we), .rd_wdata(p_rd_wdata),
        .redirect(p_redirect), .redirect_pc(p_redirect_pc),
        .trap(p_trap), .irq_taken(p_irq), .mret(p_mret), .cause_o(p_cause));

    logic br_flush;
    assign br_flush    = valid_ex && !p_trap && (bu_taken || jalr_ex);
    assign flush       = p_redirect || br_flush;
    assign redirect_pc = p_redirect ? p_redirect_pc :
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

    // ---- load/store unit (optional MMU -> D-cache / uncached bus) ----
    localparam logic [1:0] L_IDLE = 2'd0, L_XLATE = 2'd1, L_ACC = 2'd2, L_CWAIT = 2'd3;
    logic [1:0]  lsu_st;
    logic [31:0] vaddr, paddr, paddr_q, load_word, load_data, st_wdata;
    logic [3:0]  st_strb;
    logic        mem_op, lsu_go, lsu_done, cacheable, acc_now;
    assign lsu_busy = (lsu_st != L_IDLE);
    assign mem_op   = valid_ex && (mem_read_ex || mem_write_ex) && !p_trap;
    assign vaddr    = alu_y;

    // MMU
    logic        mmu_req_valid, mmu_req_ready, mmu_resp_valid, mmu_pf, mmu_af;
    logic [33:0] mmu_paddr;
    logic [3:0]  mmu_cause;
    logic        ptw_req_valid, ptw_req_ready, ptw_resp_valid, ptw_resp_ready;
    logic [33:0] ptw_addr;
    logic        ptw_pend;     // PTW read outstanding on the shared bus
    logic [31:0] ptw_addr_q;

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
    assign mmu_req_valid = USE_MMU && mem_op && lsu_st == L_IDLE;

    always_comb begin
        lsu_done  = 1'b0;
        load_word = dmem_rdata;
        if (st_now || ld_unc_now) lsu_done = 1'b1;
        if (lsu_st == L_CWAIT && dc_resp_valid) begin lsu_done = 1'b1; load_word = dc_resp_rdata; end
        if (lsu_st == L_XLATE && mmu_resp_valid && (mmu_pf || mmu_af)) lsu_done = 1'b1; // squashed
    end

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
            .satp, .priv(priv_mode), .sum(1'b0), .mxr(1'b0), .flush(1'b0),
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
        assign ptw_req_ready  = !ptw_pend;
        assign ptw_resp_valid = ptw_pend;
    end else begin : g_nommu
        assign mmu_req_ready = 1'b0; assign mmu_resp_valid = 1'b0;
        assign mmu_paddr = '0; assign mmu_pf = 1'b0; assign mmu_af = 1'b0; assign mmu_cause = '0;
        assign ptw_req_valid = 1'b0; assign ptw_addr = '0; assign ptw_resp_ready = 1'b0;
        assign ptw_req_ready = 1'b0; assign ptw_resp_valid = 1'b0;
        assign ptw_pend = 1'b0; assign ptw_addr_q = '0;
    end endgenerate

    // ---- shared data bus mux: cache refill > PTW > core access ----
    always_comb begin
        dmem_re = 1'b0; dmem_we = 1'b0; dmem_addr = paddr; dmem_wdata = st_wdata; dmem_wstrb = 4'b0;
        if (dc_mem_re) begin
            dmem_re = 1'b1; dmem_addr = dc_mem_addr;
        end else if (ptw_pend) begin
            dmem_re = 1'b1; dmem_addr = ptw_addr_q;
        end else if (st_now) begin
            dmem_we = 1'b1; dmem_wstrb = st_strb;
        end else if (ld_unc_now) begin
            dmem_re = 1'b1;
        end
    end

    // ---- stall / writeback ----
    assign stall = !p_trap && ((valid_ex && is_mul_ex && !mul_done) || (mem_op && !lsu_done));

    always_comb begin
        if (is_mul_ex)            ex_result = mul_result;
        else if (mem_read_ex)     ex_result = load_data;
        else if (p_rd_we)         ex_result = p_rd_wdata;
        else if (wb_sel_ex == 2)  ex_result = pc_ex + 32'd4;
        else                      ex_result = alu_y;
    end

    logic squash_ld;
    assign squash_ld = (lsu_st == L_XLATE) && mmu_resp_valid && (mmu_pf || mmu_af);
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
