# Memory Map

**Status:** Phase 0 — design freeze  
**Reset PC:** `0x0000_0000`  
**Date:** 2026-10-19

## 1. Address regions

| Address range              | Block                     | Size   | Access     | Notes                                      |
|----------------------------|---------------------------|--------|------------|--------------------------------------------|
| `0x0000_0000`–`0x0000_FFFF`| Boot ROM                  | 64 KiB | Read-only  | Reset vector and initial instruction image |
| `0x1000_0000`–`0x1000_FFFF`| Main SRAM                 | 64 KiB | Read/write | Primary data and code memory               |
| `0x2000_0000`–`0x2000_0FFF`| UART                      | 4 KiB  | Read/write | Serial console registers                   |
| `0x2000_1000`–`0x2000_1FFF`| GPIO                      | 4 KiB  | Read/write | General-purpose I/O registers              |
| `0x2000_2000`–`0x2000_2FFF`| Timer                     | 4 KiB  | Read/write | Timer and interrupt control                |

All other addresses are unmapped. Accesses to unmapped addresses should generate an exception or return a defined error response (exact behavior to be specified in the bus interface).

## 2. Reset and boot

- Reset PC = `0x0000_0000` (start of Boot ROM).
- The linker script and boot image must use the same map.
- Boot ROM contains the initial program; it may copy itself or a larger image into SRAM and jump there.

## 3. Peripheral register layout (initial)

Exact offsets are frozen when each peripheral RTL is written. Placeholder layout:

### UART (`0x2000_0000`)
| Offset | Register   | Access | Description          |
|--------|------------|--------|----------------------|
| 0x00   | DATA       | R/W    | Transmit / receive   |
| 0x04   | STATUS     | R      | TX ready, RX valid   |
| 0x08   | CONTROL    | R/W    | Enable, baud select  |

### GPIO (`0x2000_1000`)
| Offset | Register   | Access | Description          |
|--------|------------|--------|----------------------|
| 0x00   | OUT        | R/W    | Output data          |
| 0x04   | IN         | R      | Input data           |
| 0x08   | DIR        | R/W    | Direction (1 = out)  |

### Timer (`0x2000_2000`)
| Offset | Register   | Access | Description          |
|--------|------------|--------|----------------------|
| 0x00   | COUNT      | R      | Current count        |
| 0x04   | COMPARE    | R/W    | Compare value        |
| 0x08   | CONTROL    | R/W    | Enable, interrupt en |

## 4. Cache and bus visibility

- Instruction fetches go through the I-cache.
- Loads and stores go through the D-cache.
- Cache refills and write-through traffic appear on the interconnect as ordinary memory transactions.
- The interconnect address decoder is the single source of truth for region routing.

## 5. Verification

- Every address region must be documented before RTL integration.
- Conflicting or overlapping ranges are not permitted.
- The linker script, boot ROM image, and RTL address decoder must agree.
