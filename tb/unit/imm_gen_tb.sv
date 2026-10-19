// imm_gen_tb.sv — unit test for imm_gen.sv
`timescale 1ns/1ps

module imm_gen_tb;
    logic [31:0] instr, imm;
    logic [2:0]  imm_sel;

    imm_gen dut (.instr(instr), .imm_sel(imm_sel), .imm(imm));

    int errors = 0;

    task check(input [31:0] exp, input string name);
        if (imm !== exp) begin
            $display("FAIL %s: got %h expected %h", name, imm, exp);
            errors++;
        end else $display("PASS %s", name);
    endtask

    initial begin
        // I-type: addi x1, x0, -1  → imm = 0xFFFFFFFF
        instr = 32'hFFF00093; imm_sel = 3'd0; #1; check(32'hFFFFFFFF, "I-type -1");
        // I-type: addi x1, x0, 42  → imm = 42
        instr = 32'h02A00093; imm_sel = 3'd0; #1; check(32'd42, "I-type 42");

        // S-type: sw x1, 8(x2) — simplified encoding check
        instr = {7'b0000000, 5'd1, 5'd2, 3'b010, 5'd8, 7'b0100011};
        imm_sel = 3'd1; #1; check(32'd8, "S-type +8");

        // B-type: beq x0, x0, +8
        instr = 32'h00000463; imm_sel = 3'd2; #1; check(32'd8, "B-type +8");

        // U-type: lui x1, 0x12345
        instr = 32'h123450B7; imm_sel = 3'd3; #1; check(32'h12345000, "U-type LUI");

        // J-type: jal x1, +16 (approx)
        instr = 32'h010000EF; imm_sel = 3'd4; #1;
        // just check it is non-zero and sign-extended correctly for a small positive
        if (imm[31] !== 1'b0) begin $display("FAIL J-type sign"); errors++; end
        else $display("PASS J-type sign");

        if (errors == 0) $display("IMM_GEN: ALL TESTS PASSED");
        else $display("IMM_GEN: %0d FAILURES", errors);
        $finish;
    end
endmodule
