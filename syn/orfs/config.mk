# ORFS config for the pipeline PPA comparison (integrated core, sky130hd).
# Same structure as the team's flow/sky130hd config; clock = 10 ns
# (docs/architecture.md target). RISCV_RTL selects the RTL tree to build.
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
export SYNTH_HDL_FRONTEND = slang
export CORE_UTILIZATION = 40
export PLACE_DENSITY    = 0.60
export SYNTH_MEMORY_MAX_BITS = 16384
export SYNTH_HIERARCHICAL = 1
