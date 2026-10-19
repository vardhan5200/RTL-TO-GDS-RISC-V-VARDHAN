// decoder_tb.sv — unit test for decoder.sv
`timescale 1ns/1ps

module decoder_tb;
    logic [31:0] instr;
    logic        illegal;
    logic [3:0]  alu_op;
    logic [2:0]  imm_sel;
    logic        alu_src_b, mem_read, mem_write, reg_write, branch, jump;
    logic [1:0]  wb_sel;

    decoder dut (
        .instr(instr), .illegal(illegal), .alu_op(alu_op), .imm_sel(imm_sel),
        .alu_src_b(alu_src_b), .mem_read(mem_read), .mem_write(mem_write),
        .reg_write(reg_write), .wb_sel(wb_sel), .branch(branch), .jump(jump)
    );

    int errors = 0;

    task check_illegal(input bit exp, input string name);
        if (illegal !== exp) begin
            $display("FAIL %s: illegal=%b expected %b", name, illegal, exp);
            errors++;
        end else $display("PASS %s", name);
    endtask

    initial begin
        // ADD x3, x1, x2
        instr = 32'h002081B3; #1;
        check_illegal(0, "ADD legal");
        if (alu_op !== 4'd0 || reg_write !== 1) begin $display("FAIL ADD controls"); errors++; end

        // ADDI x1, x0, 10
        instr = 32'h00A00093; #1;
        check_illegal(0, "ADDI legal");
        if (alu_src_b !== 1 || imm_sel !== 0) begin $display("FAIL ADDI imm"); errors++; end

        // LW x4, 0(x0)
        instr = 32'h00002203; #1;
        check_illegal(0, "LW legal");
        if (mem_read !== 1 || wb_sel !== 2'd1) begin $display("FAIL LW"); errors++; end

        // SW x3, 0(x0)
        instr = 32'h00302023; #1;
        check_illegal(0, "SW legal");
        if (mem_write !== 1) begin $display("FAIL SW"); errors++; end

        // BEQ
        instr = 32'h00000063; #1;
        check_illegal(0, "BEQ legal");
        if (branch !== 1) begin $display("FAIL BEQ"); errors++; end

        // JAL
        instr = 32'h0000006F; #1;
        check_illegal(0, "JAL legal");
        if (jump !== 1 || wb_sel !== 2'd2) begin $display("FAIL JAL"); errors++; end

        // Illegal opcode
        instr = 32'h0000007F; #1;
        check_illegal(1, "illegal opcode");

        if (errors == 0) $display("DECODER: ALL TESTS PASSED");
        else $display("DECODER: %0d FAILURES", errors);
        $finish;
    end
endmodule
