// pipeline_branch.sv — 3-stage (IF / ID / EX+WB) RV32I pipeline with
// branch resolution in EX, IF/ID flush on redirect, EX->ID forwarding,
// and the iterative M-extension multiplier (rtl/cpu/mul.sv) in EX.
//
// Branch timing: a branch/jump is resolved in EX. When it is taken, the
// two younger instructions (the one in ID and the one being fetched in IF)
// are on the wrong path and are squashed, giving a 2-cycle taken penalty.
// next_pc is computed from the branch's own PC (pc_ex), not the fetch PC.
//
// MUL: when a MUL reaches EX, mul.start is pulsed once and IF/ID/EX stall
// until mul.done; the result is written back (and forwarded to ID) on the
// done cycle. Only MUL (funct3=000) is supported; MULH*/DIV*/REM* are
// treated as illegal (NOP) for now.
`timescale 1ns/1ps

module pipeline_branch (
    input  logic        clk, rst_n,
    output logic [31:0] imem_addr,
    input  logic [31:0] imem_rdata,
    output logic        dmem_we,
    output logic [31:0] dmem_addr,
    output logic [31:0] dmem_wdata,
    input  logic [31:0] dmem_rdata
);
    localparam logic [31:0] NOP = 32'h0000_0013;

    logic        stall;      // EX is waiting for a multi-cycle unit
    logic        flush;      // taken branch/jump in EX
    logic        retire;     // an instruction completes EX this cycle
    logic [31:0] pc, next_pc, redirect_pc;

    // ---------------- IF ----------------
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n)      pc <= 32'h0;
        else if (!stall) pc <= next_pc;
    assign imem_addr = pc;

    logic [31:0] instr_id, pc_id;
    logic        bubble_id;  // 1 = slot holds a reset/squash bubble, not a real instruction
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)      begin instr_id <= NOP; pc_id <= 32'h0; bubble_id <= 1; end
        else if (flush)  begin instr_id <= NOP; pc_id <= 32'h0; bubble_id <= 1; end // squash wrong path
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

    // M extension: MUL only (funct7=0000001, funct3=000)
    logic is_mul_id, valid_id;
    assign is_mul_id = (opcode_id == 7'b0110011) && (instr_id[31:25] == 7'h01) &&
                       (funct3_id == 3'b000);
    // Loads/stores are not implemented in this pipeline yet -> NOP.
    assign valid_id  = !bubble_id && (!illegal_id || is_mul_id) && !mem_read_id && !mem_write_id;

    // Register file (x0 hard-wired) with EX->ID forwarding
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
    logic [31:0] pc_ex, rd1_ex, rd2_ex, imm_ex;
    logic [3:0]  alu_op_ex;
    logic [2:0]  funct3_ex;
    logic [6:0]  opcode_ex;
    logic [1:0]  wb_sel_ex;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n || flush) begin   // reset, or bubble behind a taken branch
            valid_ex <= 0; reg_write_ex <= 0; alu_src_b_ex <= 0;
            branch_ex <= 0; jump_ex <= 0; jalr_ex <= 0; is_mul_ex <= 0;
            pc_ex <= 0; rd1_ex <= 0; rd2_ex <= 0; imm_ex <= 0;
            alu_op_ex <= 0; funct3_ex <= 0; opcode_ex <= 0; wb_sel_ex <= 0; rd_ex <= 0;
        end else if (!stall) begin
            valid_ex     <= valid_id;
            reg_write_ex <= reg_write_id && valid_id;
            alu_src_b_ex <= alu_src_b_id;
            branch_ex    <= branch_id && valid_id;
            jump_ex      <= jump_id && valid_id;
            jalr_ex      <= jalr_id && valid_id;
            is_mul_ex    <= is_mul_id;
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

    assign flush       = valid_ex && (bu_taken || jalr_ex);
    assign redirect_pc = jalr_ex ? ((rd1_ex + imm_ex) & ~32'h1) : bu_target;
    assign next_pc     = flush ? redirect_pc : pc + 32'd4;

    // Multiplier handshake
    logic mul_start, mul_done, mul_wait;
    logic [31:0] mul_result;
    assign mul_start = valid_ex && is_mul_ex && !mul_wait;
    mul u_mul (.clk, .rst_n, .start(mul_start), .a(rd1_ex), .b(rd2_ex),
               .result(mul_result), .done(mul_done));
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n)         mul_wait <= 0;
        else if (mul_start) mul_wait <= 1;
        else if (mul_done)  mul_wait <= 0;
    assign stall = valid_ex && is_mul_ex && !mul_done;

    always_comb begin
        if (is_mul_ex)            ex_result = mul_result;
        else if (wb_sel_ex == 2)  ex_result = pc_ex + 32'd4; // JAL/JALR link
        else                      ex_result = alu_y;
    end

    // ---------------- WB (end of EX) ----------------
    assign ex_wen = valid_ex && reg_write_ex && (rd_ex != 0) && !stall;
    assign retire = valid_ex && !stall;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < 32; i++) regs[i] <= 32'h0;
        end else if (ex_wen) begin
            regs[rd_ex] <= ex_result;
        end
    end

    assign dmem_we    = 1'b0;
    assign dmem_addr  = 32'h0;
    assign dmem_wdata = 32'h0;
endmodule
