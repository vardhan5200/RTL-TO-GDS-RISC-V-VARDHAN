# Regression entry points (Icarus Verilog, iverilog -g2012 + vvp).
#   make test   - everything below
SIM_OUT ?= /tmp/riscv_sim
IV      := iverilog -g2012
export SIM_OUT
SHELL := /bin/bash
.SHELLFLAGS := -o pipefail -c

.PHONY: test test-unit test-pipeline test-cache test-priv test-mmu test-soc test-integration

test: test-unit test-pipeline test-cache test-priv test-mmu test-soc test-integration
	@echo "== make test: all suites passed"

# Pre-existing self-checking unit / single-cycle / legacy SoC benches
UNIT := alu_tb:tb/unit/alu_tb.sv dec_tb:tb/unit/dec_tb.sv decoder_tb:tb/unit/decoder_tb.sv \
        imm_gen_tb:tb/unit/imm_gen_tb.sv mul_tb:tb/unit/mul_tb.sv div_tb:tb/unit/div_tb.sv \
        div_unit_tb:tb/unit/div_unit_tb.sv \
        sc_full_tb:tb/cpu/sc_full_tb.sv soc:soc.sv soc_min:soc_min.sv soc_timer:soc_timer.sv
test-unit:
	@mkdir -p $(SIM_OUT); fail=0; for e in $(UNIT); do t=$${e%%:*}; f=$${e#*:}; \
	  $(IV) -s $$t -o $(SIM_OUT)/$$t.vvp rtl/cpu/*.sv rtl/memory/simple_memory.sv $$f 2>/dev/null || { fail=1; continue; }; \
	  r=$$(vvp -n $(SIM_OUT)/$$t.vvp | grep -E "PASS|FAIL" | tail -1); echo "$$t: $$r"; \
	  echo "$$r" | grep -q PASS && ! echo "$$r" | grep -q FAIL || fail=1; done; [ $$fail -eq 0 ]

test-pipeline:
	bash tb/pipeline/run_pipeline_tests.sh

test-cache:
	@mkdir -p $(SIM_OUT); $(IV) -s dm_cache_refill_tb -o $(SIM_OUT)/dm_cache_refill.vvp \
	  rtl/cache/dm_cache.sv tb/cache/dm_cache_refill_tb.sv && \
	  vvp -n $(SIM_OUT)/dm_cache_refill.vvp | tee $(SIM_OUT)/dm_cache_refill.log | grep SUMMARY && \
	  grep -q "ALL PASS" $(SIM_OUT)/dm_cache_refill.log

test-priv:
	bash tb/priv/run.sh | grep -E "^PRIV"

test-mmu:
	sh tb/mmu/run.sh | grep -E "^MMU: ALL TESTS PASSED"

test-soc:
	bash tb/soc/run.sh | grep -E "TEST|SOC TESTS"

test-integration:
	bash tb/integration/run.sh
