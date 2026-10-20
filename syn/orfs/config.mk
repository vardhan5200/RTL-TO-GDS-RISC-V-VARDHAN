# ORFS (OpenROAD-flow-scripts) config for the integrated core on sky130hd.
# This is the single sky130hd flow of the repo. Entry points: syn/orfs/run.sh (full run + report),
# report_only.sh, power_only.sh (VCD), power_act.sh (per-net activity).
#
# Top: core_top (rtl/core/core_top.sv) with its default parameters
# (USE_ICACHE=1, USE_MMU=0). imem_*/dmem_* stay top-level ports: no ROM/SRAM,
# no SoC wrapper, no testbenches.
# FLOW_VARIANT=mmu builds the same top with USE_MMU=1 (D- and I-side Sv32 MMUs).
# Clock: 10 ns default (docs/architecture.md target), override with
# CLK_PERIOD_NS=<ns>; I/O delays are 20 % of the period (constraint.sdc).
# RISCV_RTL selects the RTL tree to build (default: this repo's rtl/).
export DESIGN_NAME     = core_top
export DESIGN_NICKNAME = core_pipe_ppa
export PLATFORM        = sky130hd
RISCV_CFG_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
RISCV_RTL     ?= $(abspath $(RISCV_CFG_DIR)/../../rtl)
export VERILOG_FILES = \
	$(RISCV_RTL)/core/core_top.sv $(RISCV_RTL)/cpu/decoder.sv $(RISCV_RTL)/cpu/imm_gen.sv \
	$(RISCV_RTL)/cpu/alu.sv $(RISCV_RTL)/cpu/branch_unit.sv $(RISCV_RTL)/cpu/mul.sv \
	$(RISCV_RTL)/cpu/div.sv $(RISCV_RTL)/cpu/div_unit.sv $(RISCV_RTL)/priv/csr_file.sv \
	$(RISCV_RTL)/priv/priv_unit.sv $(RISCV_RTL)/cache/dm_cache.sv $(RISCV_RTL)/cache/icache.sv $(RISCV_RTL)/mmu/sv32_tlb.sv \
	$(RISCV_RTL)/mmu/sv32_perm_check.sv $(RISCV_RTL)/mmu/sv32_ptw.sv $(RISCV_RTL)/mmu/sv32_mmu.sv
export SDC_FILE = $(RISCV_CFG_DIR)/constraint.sdc
# SystemVerilog front end built into Yosys >= 0.67
export SYNTH_HDL_FRONTEND = slang

ifeq ($(FLOW_VARIANT),mmu)
export VERILOG_TOP_PARAMS = USE_MMU 1
endif

export CORE_UTILIZATION = 40
export PLACE_DENSITY    = 0.60
# The D-cache / I-cache arrays and the register file are plain SV arrays and no
# SRAM macro is used, so they map to flip-flops. Allow that (ORFS default limit
# is 4096 bits; the D-cache data array alone is 8192 bits).
export SYNTH_MEMORY_MAX_BITS = 16384
# Keep module boundaries so synth_stat.txt gives per-module area.
export SYNTH_HIERARCHICAL = 1
