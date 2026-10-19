// pipe_min.sv — step 3d: store-to-load forwarding
`timescale 1ns/1ps

module pipe_min;
    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    logic [31:0] imem [0:15];
    initial begin
        imem[0] = 32'h00A00093; // addi x1, x0, 10
        imem[1] = 32'h01400113; // addi x2, x0, 20
        imem[2] = 32'h002081B3; // add  x3, x1, x2
        imem[3] = 32'h00302023; // sw   x3, 0(x0)
        imem[4] = 32'h00002203; // lw   x4, 0(x0)
        for (int i = 5; i < 16; i++) imem[i] = 32'h00000013;
    end

    logic [31:0] pc, instr;
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) pc <= 0;
        else        pc <= pc + 4;
    assign instr = imem[pc[5:2]];

    logic [31:0] regs [0:31];
    logic [31:0] dmem [0:15];
    integer i;
    initial begin
        for (i = 0; i < 32; i++) regs[i] = 0;
        for (i = 0; i < 16; i++) dmem[i] = 0;
    end

    logic [31:0] instr_id, rd1_ex, rd2_ex, imm_ex;
    logic [31:0] alu_y_mem, store_data_mem, alu_y_wb, load_data_wb;
    logic [4:0]  rd_ex, rd_mem, rd_wb, rs1_ex, rs2_ex;
    logic        we_ex, we_mem, we_wb;
    logic        is_addi_ex, is_add_ex, is_sw_ex, is_lw_ex;
    logic        is_sw_mem, is_lw_mem, is_lw_wb;

    logic [31:0] imm_id, rd1_id, rd2_id;
    logic [4:0] rs1_id, rs2_id, rd_id;
    logic is_addi_id, is_add_id, is_sw_id, is_lw_id;

    always @(*) begin
        rs1_id = instr_id[19:15];
        rs2_id = instr_id[24:20];
        rd_id  = instr_id[11:7];
        if (instr_id[6:0] == 7'b0100011)
            imm_id = {{20{instr_id[31]}}, instr_id[31:25], instr_id[11:7]};
        else
            imm_id = {{20{instr_id[31]}}, instr_id[31:20]};
        rd1_id = (rs1_id == 0) ? 0 : regs[rs1_id];
        rd2_id = (rs2_id == 0) ? 0 : regs[rs2_id];
        is_addi_id = (instr_id[6:0] == 7'b0010011);
        is_add_id  = (instr_id[6:0] == 7'b0110011);
        is_sw_id   = (instr_id[6:0] == 7'b0100011);
        is_lw_id   = (instr_id[6:0] == 7'b0000011);
    end

    logic [31:0] fwd_a, fwd_b, alu_y;
    always @(*) begin
        fwd_a = rd1_ex;
        fwd_b = rd2_ex;
        if (we_mem && rd_mem != 0 && rd_mem == rs1_ex) fwd_a = alu_y_mem;
        else if (we_wb && rd_wb != 0 && rd_wb == rs1_ex) fwd_a = alu_y_wb;
        if (we_mem && rd_mem != 0 && rd_mem == rs2_ex) fwd_b = alu_y_mem;
        else if (we_wb && rd_wb != 0 && rd_wb == rs2_ex) fwd_b = alu_y_wb;

        if (is_addi_ex || is_lw_ex || is_sw_ex)
            alu_y = fwd_a + imm_ex;
        else
            alu_y = fwd_a + fwd_b;
    end

    always_ff @(posedge clk) begin
        if (is_sw_mem)
            dmem[alu_y_mem[5:2]] <= store_data_mem;
    end

    // Load data with store-to-load forwarding
    logic [31:0] load_data_mem;
    always @(*) begin
        if (is_sw_mem && is_lw_ex && (alu_y_mem[5:2] == alu_y[5:2]))
            load_data_mem = store_data_mem;          // forward from store
        else
            load_data_mem = dmem[alu_y_mem[5:2]];
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 1; i < 32; i++) regs[i] <= 0;
        end else if (we_wb && rd_wb != 0) begin
            regs[rd_wb] <= is_lw_wb ? load_data_wb : alu_y_wb;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            instr_id <= 0; rd1_ex <= 0; rd2_ex <= 0; imm_ex <= 0;
            rd_ex <= 0; rs1_ex <= 0; rs2_ex <= 0;
            we_ex <= 0; is_addi_ex <= 0; is_add_ex <= 0; is_sw_ex <= 0; is_lw_ex <= 0;
            alu_y_mem <= 0; store_data_mem <= 0; rd_mem <= 0; we_mem <= 0;
            is_sw_mem <= 0; is_lw_mem <= 0;
            alu_y_wb <= 0; load_data_wb <= 0; rd_wb <= 0; we_wb <= 0; is_lw_wb <= 0;
        end else begin
            instr_id <= instr;
            rd1_ex <= rd1_id; rd2_ex <= rd2_id; imm_ex <= imm_id;
            rd_ex <= rd_id; rs1_ex <= rs1_id; rs2_ex <= rs2_id;
            we_ex <= is_addi_id || is_add_id || is_lw_id;
            is_addi_ex <= is_addi_id; is_add_ex <= is_add_id;
            is_sw_ex <= is_sw_id; is_lw_ex <= is_lw_id;
            alu_y_mem <= alu_y;
            store_data_mem <= fwd_b;
            rd_mem <= rd_ex; we_mem <= we_ex;
            is_sw_mem <= is_sw_ex; is_lw_mem <= is_lw_ex;
            alu_y_wb <= alu_y_mem;
            load_data_wb <= load_data_mem;
            rd_wb <= rd_mem; we_wb <= we_mem;
            is_lw_wb <= is_lw_mem;
        end
    end

    initial begin
        rst_n = 0; #20; rst_n = 1;
        repeat (15) @(posedge clk); #1;
        $display("x1=%0d x2=%0d x3=%0d x4=%0d mem0=%0d",
                 regs[1], regs[2], regs[3], regs[4], dmem[0]);
        if (regs[1]==10 && regs[2]==20 && regs[3]==30 && regs[4]==30 && dmem[0]==30)
            $display("STEP3d: FULL PROGRAM PASSED");
        else
            $display("STEP3d: FAILED");
        $finish;
    end
endmodule
