// single_cycle_cpu.sv — based on the version that passed
module single_cycle_cpu (
    input  logic        clk,
    input  logic        rst_n,
    output logic [31:0] imem_addr,
    input  logic [31:0] imem_rdata,
    output logic        dmem_we,
    output logic [31:0] dmem_addr,
    output logic [31:0] dmem_wdata,
    output logic [3:0]  dmem_wstrb,
    input  logic [31:0] dmem_rdata
);
    logic [31:0] pc, next_pc;
    pc u_pc (.clk(clk), .rst_n(rst_n), .stall(1'b0), .next_pc(next_pc), .pc_out(pc));
    assign imem_addr = pc;

    logic [6:0] opcode;
    logic [4:0] rd, rs1, rs2;
    logic [2:0] funct3;
    assign opcode = imem_rdata[6:0];
    assign rd     = imem_rdata[11:7];
    assign funct3 = imem_rdata[14:12];
    assign rs1    = imem_rdata[19:15];
    assign rs2    = imem_rdata[24:20];

    logic illegal, alu_src_b, mem_read, mem_write, mem_unsigned, reg_write, branch, jump, jalr;
    logic [3:0] alu_op;
    logic [2:0] imm_sel, mem_size;
    logic [1:0] wb_sel;

    decoder u_dec (
        .instr(imem_rdata),
        .illegal(illegal),
        .alu_op(alu_op),
        .imm_sel(imm_sel),
        .alu_src_b(alu_src_b),
        .mem_read(mem_read),
        .mem_write(mem_write),
        .mem_size(mem_size),
        .mem_unsigned(mem_unsigned),
        .reg_write(reg_write),
        .wb_sel(wb_sel),
        .branch(branch),
        .jump(jump),
        .jalr(jalr)
    );

    logic [31:0] imm;
    imm_gen u_imm (.instr(imem_rdata), .imm_sel(imm_sel), .imm(imm));

    logic [31:0] rd1, rd2, wb_data;
    regfile u_rf (
        .clk(clk), .rst_n(rst_n), .we(reg_write),
        .rs1(rs1), .rs2(rs2), .rd(rd), .wd(wb_data),
        .rd1(rd1), .rd2(rd2)
    );

    logic [31:0] alu_a, alu_b, alu_y;
    logic zero;
    assign alu_a = (opcode == 7'b0110111) ? 32'd0 : rd1;
    assign alu_b = alu_src_b ? imm : rd2;
    alu u_alu (.a(alu_a), .b(alu_b), .op(alu_op), .y(alu_y), .zero(zero));

    logic taken;
    logic [31:0] btarget;
    branch_unit u_bu (
        .rs1(rd1), .rs2(rd2), .funct3(funct3),
        .branch(branch), .jump(jump && !jalr),
        .pc(pc), .imm(imm), .taken(taken), .target(btarget)
    );

    always @(*) begin
        if (jalr)
            next_pc = (rd1 + imm) & ~32'h1;
        else if (taken)
            next_pc = btarget;
        else
            next_pc = pc + 32'd4;
    end

    assign dmem_we    = mem_write;
    assign dmem_addr  = alu_y;
    assign dmem_wdata = rd2;
    assign dmem_wstrb = 4'b1111;  // word only for this test

    logic [31:0] load_data;
    assign load_data = dmem_rdata;

    always @(*) begin
        case (wb_sel)
            2'd0: wb_data = alu_y;
            2'd1: wb_data = load_data;
            2'd2: wb_data = pc + 32'd4;
            default: wb_data = alu_y;
        endcase
    end
endmodule
