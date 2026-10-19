#!/bin/sh
# Build and run the Sv32 MMU testbench with Icarus Verilog (from repo root).
# The compiled image goes to /tmp so nothing is written into sim/.
set -e
cd "$(dirname "$0")/../.."
iverilog -g2012 -Wall -Wno-timescale -s tb_sv32_mmu -o /tmp/mmu.vvp rtl/mmu/*.sv tb/mmu/tb_sv32_mmu.sv
vvp -n /tmp/mmu.vvp
