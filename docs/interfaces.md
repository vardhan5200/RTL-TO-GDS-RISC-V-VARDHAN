# Interfaces

**Status:** Phase 0 — design freeze  
**Protocol:** Ready/valid handshake  
**Date:** 2026-10-19

## 1. Ready/valid handshake

A request is accepted only when both `valid` and `ready` are high on the sampling clock edge.

```
valid  ─────┐     ┌─────────
            └─────┘
ready  ───────────┐     ┌───
                  └─────┘
            accepted here
```

- The sender must hold the request stable until it is accepted.
- The receiver may deassert `ready` to apply backpressure.
- A response must remain associated with its request until the receiving block accepts it.
- No combinatorial loops between `valid` and `ready` of the same channel.

## 2. CPU ↔ I-Cache (instruction fetch)

| Signal          | Direction | Width | Description                     |
|-----------------|-----------|-------|---------------------------------|
| `req_valid`     | CPU → IC  | 1     | Fetch request valid             |
| `req_ready`     | IC → CPU  | 1     | Cache can accept request        |
| `req_addr`      | CPU → IC  | 32    | Byte address (word-aligned)     |
| `resp_valid`    | IC → CPU  | 1     | Instruction data valid          |
| `resp_ready`    | CPU → IC  | 1     | CPU can accept response         |
| `resp_data`     | IC → CPU  | 32    | Instruction word                |
| `resp_error`    | IC → CPU  | 1     | Bus error / unmapped (optional) |

## 3. CPU ↔ D-Cache (load/store)

| Signal          | Direction | Width | Description                     |
|-----------------|-----------|-------|---------------------------------|
| `req_valid`     | CPU → DC  | 1     | Memory request valid            |
| `req_ready`     | DC → CPU  | 1     | Cache can accept request        |
| `req_addr`      | CPU → DC  | 32    | Byte address                    |
| `req_we`        | CPU → DC  | 1     | Write enable (1 = store)        |
| `req_wdata`     | CPU → DC  | 32    | Write data                      |
| `req_wstrb`     | CPU → DC  | 4     | Byte write strobes              |
| `resp_valid`    | DC → CPU  | 1     | Response valid                  |
| `resp_ready`    | CPU → DC  | 1     | CPU can accept response         |
| `resp_rdata`    | DC → CPU  | 32    | Read data                       |
| `resp_error`    | DC → CPU  | 1     | Bus error / unmapped (optional) |

First version: word-aligned accesses only (`req_wstrb = 4'b1111` or single-byte later).

## 4. Cache ↔ Memory interconnect (refill / write-through)

Both I-cache and D-cache use the same lower-memory interface.

| Signal          | Direction     | Width | Description                     |
|-----------------|---------------|-------|---------------------------------|
| `mem_req_valid` | Cache → Mem   | 1     | Request valid                   |
| `mem_req_ready` | Mem → Cache   | 1     | Memory can accept               |
| `mem_req_addr`  | Cache → Mem   | 32    | Line-aligned address            |
| `mem_req_we`    | Cache → Mem   | 1     | Write (D-cache write-through)   |
| `mem_req_wdata` | Cache → Mem   | 128   | Line data (or 32-bit bursts)    |
| `mem_resp_valid`| Mem → Cache   | 1     | Response valid                  |
| `mem_resp_ready`| Cache → Mem   | 1     | Cache can accept response       |
| `mem_resp_rdata`| Mem → Cache   | 128   | Line data                       |
| `mem_resp_error`| Mem → Cache   | 1     | Error                           |

Arbitration is required when both caches request memory in the same cycle. The arbiter is fair or prioritizes I-cache for the first version (exact policy documented in the arbiter RTL).

## 5. Reset behavior

- Reset may be synchronous or asynchronous; the choice must be documented and used consistently.
- On reset assertion:
  - All valid bits in caches are cleared.
  - Pipeline registers are cleared or set to a NOP/bubble state.
  - PC is set to `0x0000_0000`.
  - Peripheral registers return to their defined reset values.
- Reset release must be clean (no spurious transactions).

## 6. Clocking

- Single clock domain for the first version (`clk`).
- All interfaces are synchronous to `clk`.
- No asynchronous crossings in the initial design.

## 7. Verification requirements

- Every interface must have a documented ready/valid protocol.
- No undocumented signals between blocks.
- Reset behavior must be checked in simulation for every major block.
- Backpressure (ready deasserted) must be tested on cache and memory interfaces.
