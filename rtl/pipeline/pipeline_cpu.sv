// pipeline_cpu.sv — known-working version (no forwarding)
module pipeline_cpu (
    input  logic        clk, rst_n,
    output logic [31:0] imem_addr,
    input  logic [31:0] imem_rdata,
    output logic        dmem_we,
    output logic [31:0] dmem_addr, dmem_wdata,
    output logic [3:0]  dmem_wstrb,
    input  logic [31:0] dmem_rdata
);
    logic [31:0] pc, next_pc;
    pc u_pc (.clk, .rst_n, .stall(1'b0), .next_pc, .pc_out(pc));
    assign imem_addr = pc;
    assign next_pc = pc + 4;

    logic [31:0] pc_id, instr_id;
    if_id u_if_id (.clk, .rst_n, .stall(1'b0), .flush(1'b0),
                   .pc_in(pc), .instr_in(imem_rdata),
                   .pc_out(pc_id), .instr_out(instr_id));

    logic [4:0] rd_id  = instr_id[11:7];
    logic [4:0] rs1_id = instr_id[19:15];
    logic [4:0] rs2_id = instr_id[24:20];

    logic illegal, alu_src_b_id, mem_read_id, mem_write_id, mem_unsigned_id;
    logic reg_write_id, branch_id, jump_id, jalr_id;
    logic [3:0] alu_op_id; logic [2:0] imm_sel, mem_size_id; logic [1:0] wb_sel_id;

    decoder u_dec (.instr(instr_id), .illegal, .alu_op(alu_op_id), .imm_sel,
                   .alu_src_b(alu_src_b_id), .mem_read(mem_read_id), .mem_write(mem_write_id),
                   .mem_size(mem_size_id), .mem_unsigned(mem_unsigned_id),
                   .reg_write(reg_write_id), .wb_sel(wb_sel_id),
                   .branch(branch_id), .jump(jump_id), .jalr(jalr_id));

    logic [31:0] imm_id, rd1_id, rd2_id, wb_data;
    logic [4:0] rd_wb; logic reg_write_wb;
    imm_gen u_imm (.instr(instr_id), .imm_sel, .imm(imm_id));
    regfile u_rf (.clk, .rst_n, .we(reg_write_wb), .rs1(rs1_id), .rs2(rs2_id),
                  .rd(rd_wb), .wd(wb_data), .rd1(rd1_id), .rd2(rd2_id));

    logic [31:0] pc_ex, rd1_ex, rd2_ex, imm_ex;
    logic [4:0] rs1_ex, rs2_ex, rd_ex;
    logic [3:0] alu_op_ex;
    logic alu_src_b_ex, mem_read_ex, mem_write_ex, reg_write_ex;
    logic branch_ex, jump_ex, jalr_ex;
    logic [1:0] wb_sel_ex; logic [2:0] mem_size_ex; logic mem_unsigned_ex;

    id_ex u_id_ex (.clk, .rst_n, .flush(1'b0),
                   .pc_in(pc_id), .rd1_in(rd1_id), .rd2_in(rd2_id), .imm_in(imm_id),
                   .rs1_in(rs1_id), .rs2_in(rs2_id), .rd_in(rd_id),
                   .alu_op_in(alu_op_id), .alu_src_b_in(alu_src_b_id),
                   .mem_read_in(mem_read_id), .mem_write_in(mem_write_id),
                   .reg_write_in(reg_write_id), .branch_in(branch_id),
                   .jump_in(jump_id), .jalr_in(jalr_id),
                   .wb_sel_in(wb_sel_id), .mem_size_in(mem_size_id),
                   .mem_unsigned_in(mem_unsigned_id),
                   .pc_out(pc_ex), .rd1_out(rd1_ex), .rd2_out(rd2_ex), .imm_out(imm_ex),
                   .rs1_out(rs1_ex), .rs2_out(rs2_ex), .rd_out(rd_ex),
                   .alu_op_out(alu_op_ex), .alu_src_b_out(alu_src_b_ex),
                   .mem_read_out(mem_read_ex), .mem_write_out(mem_write_ex),
                   .reg_write_out(reg_write_ex), .branch_out(branch_ex),
                   .jump_out(jump_ex), .jalr_out(jalr_ex),
                   .wb_sel_out(wb_sel_ex), .mem_size_out(mem_size_ex),
                   .mem_unsigned_out(mem_unsigned_ex));

    logic [31:0] alu_a, alu_b, alu_y;
    logic zero;
    always @(*) begin
        alu_a = rd1_ex;
        if (alu_src_b_ex)
            alu_b = imm_ex;
        else
            alu_b = rd2_ex;
    end
    alu u_alu (.a(alu_a), .b(alu_b), .op(alu_op_ex), .y(alu_y), .zero);

    logic [31:0] alu_y_mem, rd2_mem, pc_mem;
    logic [4:0] rd_mem;
    logic mem_read_mem, mem_write_mem, reg_write_mem;
    logic [1:0] wb_sel_mem; logic [2:0] mem_size_mem;

    ex_mem u_ex_mem (.clk, .rst_n,
                     .alu_y_in(alu_y), .rd2_in(rd2_ex), .pc_in(pc_ex), .rd_in(rd_ex),
                     .mem_read_in(mem_read_ex), .mem_write_in(mem_write_ex),
                     .reg_write_in(reg_write_ex), .wb_sel_in(wb_sel_ex),
                     .mem_size_in(mem_size_ex),
                     .alu_y_out(alu_y_mem), .rd2_out(rd2_mem), .pc_out(pc_mem),
                     .rd_out(rd_mem), .mem_read_out(mem_read_mem),
                     .mem_write_out(mem_write_mem), .reg_write_out(reg_write_mem),
                     .wb_sel_out(wb_sel_mem), .mem_size_out(mem_size_mem));

    assign dmem_we = mem_write_mem;
    assign dmem_addr = alu_y_mem;
    assign dmem_wdata = rd2_mem;
    assign dmem_wstrb = 4'b1111;

    logic [31:0] alu_y_wb, load_data_wb, pc_wb;
    logic [1:0] wb_sel_wb;

    mem_wb u_mem_wb (.clk, .rst_n,
                     .alu_y_in(alu_y_mem), .load_data_in(dmem_rdata), .pc_in(pc_mem),
                     .rd_in(rd_mem), .reg_write_in(reg_write_mem), .wb_sel_in(wb_sel_mem),
                     .alu_y_out(alu_y_wb), .load_data_out(load_data_wb), .pc_out(pc_wb),
                     .rd_out(rd_wb), .reg_write_out(reg_write_wb), .wb_sel_out(wb_sel_wb));

    always @(*) begin
        case (wb_sel_wb)
            0: wb_data = alu_y_wb;
            1: wb_data = load_data_wb;
            2: wb_data = pc_wb + 4;
            default: wb_data = alu_y_wb;
        endcase
    end
endmodule
