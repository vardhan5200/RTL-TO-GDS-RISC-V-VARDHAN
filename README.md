# RTL-to-GDS RISC-V (Vardhan)

Open-source RV32I processor development: architecture → RTL → verification → physical design (SkyWater 130 nm).

## Current status

| Component | Status | Notes |
|-----------|--------|-------|
| Architecture docs | Done | Phase 0 freeze |
| ALU / imm_gen / decoder | Done | Full RV32I base |
| Single-cycle reference CPU | Done | Functional oracle |
| Minimal 5-stage pipeline | Done | ADDI/ADD/SW/LW + forwarding (`pipe_min.sv`) |
| Minimal SoC | Done | Boot ROM, SRAM, UART, GPIO, done flag |
| L1 caches | Partial | Control works; data path needs more work |
| Physical design (GDS) | Not started | OpenROAD + SKY130 ready |

## Repository layout

```
docs/                  Phase 0 specifications
rtl/cpu/               ALU, decoder, regfile, single-cycle CPU
rtl/pipeline/          Pipeline stages + pipe_min_working.sv
rtl/cache/             Direct-mapped cache experiments
rtl/memory/            Simple memory model
tb/                    Unit and system testbenches
soc.sv / soc_min.sv    Working SoC examples
```

## Quick simulation

```bash
# Minimal SoC (prints "Hi" on UART and sets GPIO)
iverilog -g2012 -s soc -o sim/soc.vvp \
  rtl/cpu/*.sv soc.sv
vvp sim/soc.vvp
```

## Tools

- OSS CAD Suite (Icarus Verilog, Yosys, GTKWave)
- OpenROAD Flow Scripts + SKY130HD (Docker)
- KLayout

## Next steps

- Add timer / more peripherals
- Harden the pipeline (branches, more instructions)
- First OpenROAD run of the single-cycle CPU or SoC wrapper
