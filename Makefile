# Regression entry points (Icarus Verilog, iverilog -g2012 + vvp).
#   make test   - everything below
#   test-ppa-check (ALU equivalence + MUL random vectors) also needs yosys.
SIM_OUT ?= /tmp/riscv_sim
IV      := iverilog -g2012
export SIM_OUT
SHELL := /bin/bash
.SHELLFLAGS := -o pipefail -c

.PHONY: test test-unit test-pipeline test-cache test-priv test-mmu test-soc test-integration test-ppa-check \
        perf test-perf perf-sw

test: test-unit test-pipeline test-cache test-priv test-mmu test-soc test-integration test-ppa-check test-perf
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

CORE_RTL := rtl/cpu/decoder.sv rtl/cpu/imm_gen.sv rtl/cpu/alu.sv rtl/cpu/branch_unit.sv rtl/cpu/mul.sv \
            rtl/cpu/div.sv rtl/cpu/div_unit.sv rtl/cache/dm_cache.sv rtl/cache/icache.sv \
            rtl/priv/csr_file.sv rtl/priv/priv_unit.sv rtl/mmu/*.sv rtl/core/core_top.sv
test-cache:
	@mkdir -p $(SIM_OUT); $(IV) -s dm_cache_refill_tb -o $(SIM_OUT)/dm_cache_refill.vvp \
	  rtl/cache/dm_cache.sv tb/cache/dm_cache_refill_tb.sv && \
	  vvp -n $(SIM_OUT)/dm_cache_refill.vvp | tee $(SIM_OUT)/dm_cache_refill.log | grep SUMMARY && \
	  grep -q "ALL PASS" $(SIM_OUT)/dm_cache_refill.log
	@$(IV) -s icache_tb -o $(SIM_OUT)/icache_tb.vvp rtl/cache/icache.sv tb/cache/icache_tb.sv && \
	  vvp -n $(SIM_OUT)/icache_tb.vvp | tee $(SIM_OUT)/icache_tb.log | grep SUMMARY && \
	  grep -q "ALL PASS" $(SIM_OUT)/icache_tb.log
	@for t in core_icache_tb core_icache_mmu_tb; do for ic in 1 0; do \
	  $(IV) -s $$t -P $$t.USE_ICACHE=$$ic -o $(SIM_OUT)/$$t$$ic.vvp $(CORE_RTL) tb/cache/$$t.sv 2>/dev/null && \
	  vvp -n $(SIM_OUT)/$$t$$ic.vvp | tee $(SIM_OUT)/$$t$$ic.log | grep -E "^core I|SUMMARY" && \
	  grep -q "ALL PASS" $(SIM_OUT)/$$t$$ic.log || exit 1; done; done

test-priv:
	bash tb/priv/run.sh | grep -E "^(CORE )?(PRIV|SMODE)"

test-mmu:
	sh tb/mmu/run.sh | grep -E "^MMU: ALL TESTS PASSED"

test-soc:
	bash tb/soc/run.sh | grep -E "TEST|SOC TESTS"

test-integration:
	bash tb/integration/run.sh

# PPA refactor checks: ALU formal equivalence vs 53f6ec9 (yosys SAT) + MUL random vectors.
test-ppa-check:
	@r=$$(SIM_OUT=$(SIM_OUT)/ppa_checks bash tb/ppa/run_ppa_checks.sh); echo "$$r"; \
	  echo "$$r" | grep -q "ALU EQUIV: PASS" && echo "$$r" | grep -q "MUL_RAND: ALL TESTS PASSED"

# SoC microbenchmarks (sw/perf on soc_core_top): CPI loop, I/D-cache cold/warm,
# MUL/DIV latency, load/store throughput, web-like request loop. Prints PERF
# lines; PASS/FAIL is functional only. Uses the committed sw/perf/perf.hex.
perf:
	bash tb/perf/run_perf.sh

# same run inside `make test`: only the per-check and suite verdict lines
test-perf:
	@r=$$(SIM_OUT=$(SIM_OUT) bash tb/perf/run_perf.sh) || { echo "$$r" | grep -E "FAIL|TIMEOUT|CHECK"; echo "PERF SUITE: FAIL"; exit 1; }; \
	  echo "$$r" | grep -E "^PERF SUITE"

# rebuild sw/perf/perf.hex (needs riscv64-unknown-elf-gcc)
perf-sw:
	$(MAKE) -C sw/perf
