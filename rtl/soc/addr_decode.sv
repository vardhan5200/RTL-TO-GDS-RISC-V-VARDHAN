// addr_decode.sv — Centralized SoC address decoder (combinational).
// Exactly one select is high for a mapped address; `unmapped` otherwise.
// Peripheral registers are decoded on the word address (addr[31:2]).
import soc_map_pkg::*;

module addr_decode (
    input  logic [31:0] addr,
    output logic        rom_sel,
    output logic        sram_sel,
    output logic        uart_sel,
    output logic        gpio_sel,
    output logic        done_sel,
    output logic        timer_sel,
    output logic        irq_sel,
    output logic        uartb_sel,   // UART register block (0x230)
    output logic        mem_sel,     // main RAM (0x1_0000)
    output logic        unmapped
);
    function automatic logic in_range(input logic [31:0] a, base, size);
        return (a >= base) && (a < base + size);
    endfunction

    always @(*) begin
        rom_sel   = in_range(addr, ROM_BASE,   ROM_SIZE);
        sram_sel  = in_range(addr, SRAM_BASE,  SRAM_SIZE);
        uart_sel  = (addr[31:2] == UART_ADDR[31:2]);
        gpio_sel  = (addr[31:2] == GPIO_ADDR[31:2]);
        done_sel  = (addr[31:2] == DONE_ADDR[31:2]);
        timer_sel = in_range(addr, TIMER_BASE, TIMER_SIZE);
        irq_sel   = in_range(addr, IRQ_BASE,   IRQ_SIZE);
        uartb_sel = in_range(addr, UART_BASE,  UART_SIZE);
        mem_sel   = in_range(addr, MEM_BASE,   MEM_SIZE);
        unmapped  = !(rom_sel | sram_sel | uart_sel | gpio_sel |
                      done_sel | timer_sel | irq_sel | uartb_sel | mem_sel);
    end
endmodule
