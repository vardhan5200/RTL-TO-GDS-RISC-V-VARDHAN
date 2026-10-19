// single_cycle_cpu.sv — explicit assigns, Icarus-safe
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

    // Explicit field extraction
    logic [6:0] opcode;
    logic [4:0] rd, rs1, rs2;
    logic [2:0] funct3;
    logic [6:0] funct7;

    assign opcode = imem_rdata[6:0];
    assign rd     = imem_rdata[11:7];
    assign funct3 = imem_rdata[14:12];
    assign rs1    = imem_rdata[19:15];
    assign rs2    = imem_rdata[24:20];
    assign funct7 = imem_rdata[31:25];

    logic        illegal;
    logic [3:0]  alu_op;
    logic [2:0]  imm_sel;
    logic        alu_src_b, mem_read, mem_write, reg_write, branch, jump;
    logic [1:0]  wb_sel;

    decoder u_dec (
        .instr(imem_rdata), .illegal(illegal), .alu_op(alu_op), .imm_sel(imm_sel),
        .alu_src_b(alu_src_b), .mem_read(mem_read), .mem_write(mem_write),
        .reg_write(reg_write), .wb_sel(wb_sel), .branch(branch), .jump(jump)
    );

    logic [31:0] imm;
    imm_gen u_imm (.instr(imem_rdata), .imm_sel(imm_sel), .imm(imm));

    logic [31:0] rd1, rd2, wb_data;
    regfile u_rf (
        .clk(clk), .rst_n(rst_n), .we(reg_write),
        .rs1(rs1), .rs2(rs2), .rd(rd), .wd(wb_data),
        .rd1(rd1), .rd2(rd2)
    );

    logic [31:0] alu_b;
    assign alu_b = alu_src_b ? imm : rd2;

    logic [31:0] alu_y;
    logic        alu_zero;
    alu u_alu (.a(rd1), .b(alu_b), .op(alu_op), .y(alu_y), .zero(alu_zero));

    logic taken;
    logic [31:0] branch_target;
    branch_unit u_bu (
        .rs1(rd1), .rs2(rd2), .funct3(funct3),
        .branch(branch), .jump(jump && (opcode != 7'b1100111)),
        .pc(pc), .imm(imm), .taken(taken), .target(branch_target)
    );

    always @(*) begin
        if (jump && (opcode == 7'b1100111))
            next_pc = (rd1 + imm) & ~32'h1;
        else if (taken)
            next_pc = branch_target;
        else
            next_pc = pc + 32'd4;
    end

    assign dmem_we    = mem_write;
    assign dmem_addr  = alu_y;
    assign dmem_wdata = rd2;
    assign dmem_wstrb = 4'b1111;

    always @(*) begin
        case (wb_sel)
            2'd0: wb_data = alu_y;
            2'd1: wb_data = dmem_rdata;
            2'd2: wb_data = pc + 32'd4;
            default: wb_data = alu_y;
        endcase
    end
endmodule
