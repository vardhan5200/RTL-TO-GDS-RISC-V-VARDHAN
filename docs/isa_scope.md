# ISA Scope — RV32I

**Status:** Phase 0 — design freeze  
**Base ISA:** RV32I (integer only)  
**Privilege:** Machine mode only (initial)  
**Date:** 2026-10-19

> **Implementation status (checkpoint `ba15d11`):** The single-cycle CPU decodes all RV32I base instructions. Loads and stores are word-only (`dmem_wstrb` is fixed to `4'b1111`, with no byte select or sign extension on loads). ECALL, EBREAK, and FENCE are decoded as no-ops. No CSRs or traps are implemented. M extension work has started ahead of the plan in §2: standalone `rtl/cpu/mul.sv` (unsigned shift-and-add, low 32 bits) and `rtl/cpu/div.sv` (repeated subtraction, small unsigned values only) pass their unit tests, but they are not yet connected into a CPU (`tb_pipe_m` fails). See [`status.md`](status.md).

## 1. Supported instruction classes

All base RV32I instructions are in scope for the final CPU. Implementation order is staged.

### 1.1 Arithmetic and logical
- `ADD`, `SUB`, `AND`, `OR`, `XOR`
- `SLT`, `SLTU`
- `SLL`, `SRL`, `SRA`
- Immediate forms: `ADDI`, `ANDI`, `ORI`, `XORI`, `SLTI`, `SLTIU`, `SLLI`, `SRLI`, `SRAI`

### 1.2 Upper immediate
- `LUI`
- `AUIPC`

### 1.3 Loads and stores
- `LW`, `LH`, `LB`, `LHU`, `LBU`
- `SW`, `SH`, `SB`

First version may support word-aligned accesses only. Byte and halfword support is added after the basic pipeline and caches are stable.

### 1.4 Branches and jumps
- `BEQ`, `BNE`, `BLT`, `BGE`, `BLTU`, `BGEU`
- `JAL`, `JALR`

Branch conditions are evaluated by a dedicated branch unit, not by testing whether an ALU result is zero.

### 1.5 System
- `ECALL`, `EBREAK` (trap behavior according to the chosen privilege specification)
- `FENCE` (treated as a no-op or memory barrier appropriate to the implemented memory system)
- `FENCE.I` (required for self-modifying code / I-cache coherence; implemented after basic caches)

## 2. Explicitly out of scope (initial)

| Extension / Feature       | Status                                      |
|---------------------------|---------------------------------------------|
| M (multiply/divide)       | In progress: standalone mul/div units exist; pipeline integration open |
| A (atomics)               | Not in first version                        |
| F / D (floating point)    | Not in first version                        |
| C (compressed)            | Not in first version                        |
| Supervisor / User mode    | Machine mode only initially                 |
| Virtual memory / Sv32     | Not in first version                        |
| Cache-maintenance ops     | Added after basic cache design is stable    |

## 3. Architectural registers

- 32 integer registers (`x0`–`x31`), 32 bits each
- `x0` hardwired to zero; writes to `x0` are ignored
- PC is 32 bits; reset value = `0x0000_0000`

## 4. Exceptions and traps (machine mode)

Initial trap support:
- Illegal instruction
- `ECALL` / `EBREAK`
- Load/store address misaligned (when misaligned access is enabled)
- Machine timer interrupt (after timer peripheral is integrated)

CSR set for machine mode (minimal):
- `mstatus`, `misa`, `mie`, `mip`, `mtvec`, `mepc`, `mcause`, `mtval`, `mscratch`
- Additional CSRs added as needed

## 5. Verification requirements

- Every supported instruction must produce the architecturally correct result versus the single-cycle reference model.
- Sign extension of immediates and load data must be correct.
- Signed vs unsigned comparisons must be distinct.
- No architectural mismatch on directed tests covering the supported subset.

## 6. Reference

The RISC-V Unprivileged ISA Specification (Volume I) and the Privileged ISA Specification (Volume II) are the authority for instruction semantics and encoding.
