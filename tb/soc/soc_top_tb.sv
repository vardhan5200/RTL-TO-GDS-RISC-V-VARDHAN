// soc_top_tb.sv — SoC-level test: CPU program touches every region,
// programs timer + irq controller, polls PENDING, services the irq, then
// does one unmapped read which must set bus_err. Also sweeps addr_decode.
`timescale 1ns/1ps
import soc_map_pkg::*;

module soc_top_tb;
    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    logic        irq, uart_valid, done, bus_err;
    logic [7:0]  uart_byte, gpio_out;
    logic [31:0] bus_err_addr;

    soc_top dut (.clk, .rst_n, .ext_irq(7'd0), .irq, .uart_byte, .uart_valid,
                 .gpio_out, .done, .bus_err, .bus_err_addr);

    int errors = 0;
    task automatic check(string what, logic [31:0] got, exp);
        if (got !== exp) begin
            $display("  FAIL %-34s got=%08h exp=%08h", what, got, exp); errors++;
        end else
            $display("  ok   %-34s = %08h", what, got);
    endtask

    // ---- standalone decoder sweep ----
    logic [31:0] da;
    logic s_rom, s_sram, s_uart, s_gpio, s_done, s_tmr, s_irq, s_un;
    addr_decode u_chk (.addr(da), .rom_sel(s_rom), .sram_sel(s_sram),
        .uart_sel(s_uart), .gpio_sel(s_gpio), .done_sel(s_done),
        .timer_sel(s_tmr), .irq_sel(s_irq), .unmapped(s_un));
    task automatic dec(logic [31:0] a, logic [7:0] exp);
        da = a; #1;
        check($sformatf("decode %08h", a),
              {s_rom, s_sram, s_uart, s_gpio, s_done, s_tmr, s_irq, s_un}, exp);
    endtask

    bit saw_irq = 0, saw_err_early = 0;
    always @(posedge clk) begin
        if (irq && !saw_irq) begin
            saw_irq = 1;
            $display("  irq asserted at %0t (timer COUNT=%0d)", $time, dut.u_timer.count);
        end
        if (uart_valid) $display("  UART: %c", uart_byte);
    end

    initial begin
        // bits: rom sram uart gpio done timer irq unmapped
        $display("soc_top_tb: decoder sweep");
        dec(32'h0000_0000, 8'b1000_0000); dec(32'h0000_00FC, 8'b1000_0000);
        dec(32'h0000_0100, 8'b0100_0000); dec(32'h0000_01FC, 8'b0100_0000);
        dec(32'h0000_0200, 8'b0010_0000); dec(32'h0000_0204, 8'b0001_0000);
        dec(32'h0000_0208, 8'b0000_1000); dec(32'h0000_020C, 8'b0000_0001);
        dec(32'h0000_0210, 8'b0000_0100); dec(32'h0000_021C, 8'b0000_0100);
        dec(32'h0000_0220, 8'b0000_0010); dec(32'h0000_022C, 8'b0000_0010);
        dec(32'h0000_0230, 8'b0000_0001); dec(32'h0000_0300, 8'b0000_0001);
        dec(32'h1000_0000, 8'b0000_0001); dec(32'hFFFF_FFFC, 8'b0000_0001);
    end

    initial begin
        #1;
        dut.rom[0]  = 32'h04800093; // addi x1,x0,'H'
        dut.rom[1]  = 32'h20102023; // sw   x1,0x200(x0)  ; UART
        dut.rom[2]  = 32'h05500113; // addi x2,x0,0x55
        dut.rom[3]  = 32'h20202223; // sw   x2,0x204(x0)  ; GPIO
        dut.rom[4]  = 32'h20402183; // lw   x3,0x204(x0)  ; GPIO readback
        dut.rom[5]  = 32'h10302023; // sw   x3,0x100(x0)  ; SRAM[0]
        dut.rom[6]  = 32'h10002203; // lw   x4,0x100(x0)  ; SRAM readback
        dut.rom[7]  = 32'h1E402E23; // sw   x4,0x1FC(x0)  ; SRAM[63]
        dut.rom[8]  = 32'h00002283; // lw   x5,0x000(x0)  ; ROM data read
        dut.rom[9]  = 32'h10502223; // sw   x5,0x104(x0)  ; SRAM[1]
        dut.rom[10] = 32'h00100313; // addi x6,x0,1
        dut.rom[11] = 32'h22602223; // sw   x6,0x224(x0)  ; IRQ ENABLE=1
        dut.rom[12] = 32'h21002383; // lw   x7,0x210(x0)  ; TIMER COUNT
        dut.rom[13] = 32'h01438393; // addi x7,x7,20
        dut.rom[14] = 32'h20702A23; // sw   x7,0x214(x0)  ; TIMER COMPARE
        dut.rom[15] = 32'h22002403; // lw   x8,0x220(x0)  ; poll IRQ PENDING
        dut.rom[16] = 32'hFE040EE3; // beq  x8,x0,-4
        dut.rom[17] = 32'h22C02483; // lw   x9,0x22C(x0)  ; IRQ CLAIM
        dut.rom[18] = 32'h10902423; // sw   x9,0x108(x0)  ; SRAM[2]
        dut.rom[19] = 32'h20602E23; // sw   x6,0x21C(x0)  ; TIMER STATUS W1C
        dut.rom[20] = 32'h22602423; // sw   x6,0x228(x0)  ; IRQ ACK src0
        dut.rom[21] = 32'h22002503; // lw   x10,0x220(x0) ; PENDING after ack
        dut.rom[22] = 32'h10A02623; // sw   x10,0x10C(x0) ; SRAM[3]
        dut.rom[23] = 32'h30002583; // lw   x11,0x300(x0) ; UNMAPPED read
        dut.rom[24] = 32'h20602423; // sw   x6,0x208(x0)  ; DONE
        dut.rom[25] = 32'h0000006F; // jal  x0,0
    end

    initial begin
        #20 rst_n = 1;
        // bus_err must stay low until the deliberate unmapped read (rom[23])
        wait (dut.imem_addr == 32'd92);
        @(negedge clk);
        check("bus_err low before unmapped read", bus_err, 0);
        fork
            wait (done);
            begin repeat (500) @(posedge clk); $display("  TIMEOUT"); errors++; end
        join_any
        #10;
        $display("soc_top_tb: program results");
        check("UART byte", uart_byte, "H");
        check("GPIO out", gpio_out, 8'h55);
        check("SRAM[0]  GPIO readback", dut.sram[0], 32'h55);
        check("SRAM[63] SRAM readback", dut.sram[63], 32'h55);
        check("SRAM[1]  ROM data read", dut.sram[1], 32'h04800093);
        check("timer->irq observed", saw_irq, 1);
        check("SRAM[2]  CLAIM while pending", dut.sram[2], 32'h8000_0000);
        check("SRAM[3]  PENDING after ACK", dut.sram[3], 32'h0);
        check("irq low at end", irq, 0);
        check("bus_err set by unmapped read", bus_err, 1);
        check("bus_err_addr", bus_err_addr, 32'h300);
        check("done", done, 1);
        if (errors == 0) $display("SOC TOP TEST: PASS");
        else             $display("SOC TOP TEST: FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
