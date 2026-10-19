// dec_tb.sv — RV32I decoder test
`timescale 1ns/1ps
module dec_tb;
    logic [31:0] instr;
    logic illegal;
    logic [3:0] alu_op;
    logic [2:0] imm_sel;
    logic alu_src_b, mem_read, mem_write, mem_unsigned, reg_write, branch, jump, jalr;
    logic [2:0] mem_size;
    logic [1:0] wb_sel;

    decoder dut (
        .instr(instr), .illegal(illegal), .alu_op(alu_op), .imm_sel(imm_sel),
        .alu_src_b(alu_src_b), .mem_read(mem_read), .mem_write(mem_write),
        .mem_size(mem_size), .mem_unsigned(mem_unsigned), .reg_write(reg_write),
        .wb_sel(wb_sel), .branch(branch), .jump(jump), .jalr(jalr)
    );

    int errors = 0;
    task check(input bit exp, input string name);
        #1;
        if (illegal !== exp) begin
            $display("FAIL %s", name);
            errors++;
        end else $display("PASS %s", name);
    endtask

    initial begin
        instr = 32'h002081B3; check(0, "ADD");
        instr = 32'h402081B3; check(0, "SUB");
        instr = 32'h00A00093; check(0, "ADDI");
        instr = 32'h00002203; check(0, "LW");
        instr = 32'h00001203; check(0, "LH");
        instr = 32'h00004203; check(0, "LBU");
        instr = 32'h00302023; check(0, "SW");
        instr = 32'h00301023; check(0, "SH");
        instr = 32'h00000063; check(0, "BEQ");
        instr = 32'h0000006F; check(0, "JAL");
        instr = 32'h00008067; check(0, "JALR");
        instr = 32'h123450B7; check(0, "LUI");
        instr = 32'h12345097; check(0, "AUIPC");
        instr = 32'h0000007F; check(1, "illegal");

        if (errors==0) $display("DECODER: ALL TESTS PASSED");
        else           $display("DECODER: %0d FAILURES", errors);
        $finish;
    end
endmodule
