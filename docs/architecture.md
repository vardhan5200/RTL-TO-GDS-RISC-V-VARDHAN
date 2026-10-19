# RISC-V SoC Architecture

**Status:** Phase 0 — design freeze  
**ISA:** RV32I  
**Pipeline:** 5-stage (IF / ID / EX / MEM / WB)  
**Process:** SkyWater SKY130 (via OpenROAD Flow Scripts)  
**Date:** 2026-10-19

## 1. Block diagram

```
                    +------------------+
                    |   Boot ROM       |
                    |  0x0000_0000     |
                    +--------+---------+
                             |
+----------------------------+----------------------------+
|                         SoC Interconnect                 |
|                    (simple address decoder)              |
+------+--------+--------+--------+--------+---------------+
       |        |        |        |        |
   +---+---+ +--+--+ +---+--+ +---+--+ +---+--+
   | SRAM  | | UART | | GPIO | |Timer | | ...  |
   |0x1000 | |0x2000| |0x2000| |0x2000| |      |
   | _0000 | |_0000| |_1000| |_2000| |      |
   +---+---+ +--+--+ +---+--+ +---+--+ +------+
       ^
       | (refill / write-through)
+------+------+          +------+------+
|  L1 I-Cache  |          |  L1 D-Cache  |
|  1 KiB DM    |          |  1 KiB DM    |
|  read-only   |          |  read/write  |
+------+-------+          +------+-------+
       ^                         ^
       |                         |
+------+-------------------------+------+
|           5-stage RV32I CPU            |
|  IF → ID → EX → MEM → WB               |
|  + hazard / forward / branch unit      |
+----------------------------------------+
```

## 2. CPU pipeline

| Stage | Name        | Responsibility                                      |
|-------|-------------|-----------------------------------------------------|
| 1     | IF          | Instruction fetch from I-cache                      |
| 2     | ID          | Decode, register read, immediate generation         |
| 3     | EX          | ALU, branch/jump resolution, forwarding             |
| 4     | MEM         | Data cache access (load/store)                      |
| 5     | WB          | Write result to register file                       |

Pipeline registers sit between every adjacent pair of stages.  
Each instruction carries its PC, decoded controls, source/destination registers, operands, and results as required.

**Hazard handling**
- RAW dependency → forwarding from EX/MEM or MEM/WB
- Load-use dependency → one-cycle stall
- Control hazard (taken branch/jump) → flush IF and ID
- Structural hazards minimized by separate I- and D-caches

**Reference model**  
A single-cycle RV32I CPU is maintained as a functional oracle. Architectural state (PC, registers, memory side-effects) must match the pipelined CPU on the same instruction streams.

## 3. Cache hierarchy

Separate direct-mapped L1 caches. No L2 in the first version.

| Parameter          | I-Cache          | D-Cache          |
|--------------------|------------------|------------------|
| Size               | 1 KiB            | 1 KiB            |
| Line size          | 16 bytes         | 16 bytes         |
| Associativity      | Direct-mapped    | Direct-mapped    |
| Words per line     | 4                | 4                |
| Policy             | Read-only        | Write-through, write-allocate |
| Miss handling      | Blocking refill  | Blocking refill  |
| Outstanding misses | 1                | 1                |

**Address decomposition (32-bit byte address)**
- Offset: 4 bits
- Index: 6 bits (64 lines)
- Tag: 22 bits

Aligned accesses only in the first version. Byte/halfword and misalignment support added later.

## 4. Memory subsystem and interconnect

- Simple explicit internal bus with ready/valid handshakes.
- Address decoder routes CPU (via caches) and cache-refill traffic to the correct target.
- Targets: Boot ROM, SRAM, UART, GPIO, Timer.
- Arbitration when both caches request lower memory simultaneously.

## 5. Peripherals (initial set)

| Peripheral | Purpose                          |
|------------|----------------------------------|
| Boot ROM   | Reset vector and initial image   |
| SRAM       | Main data / instruction memory   |
| UART       | Serial output for bring-up       |
| GPIO       | Simple I/O for test signatures   |
| Timer      | Basic timing; interrupts later   |

Interrupts and additional peripherals are added after basic integration.

## 6. Reset and clock

- Reset PC = `0x0000_0000`
- Clock target for experimentation: 10 ns period (not a guaranteed frequency)
- Reset strategy (synchronous or asynchronous assertion/release) must be defined explicitly and verified consistently

## 7. Physical implementation target

- Library: SKY130 standard cells (sky130hd)
- Flow: OpenROAD Flow Scripts
- Goal: manufacturable-style digital layout (GDSII), not merely a synthesized netlist
