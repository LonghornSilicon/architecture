# Longhorn Silicon — Product Requirements Document (Prudent)

**KV Cache Compression Engine — Tape-out Target**

**Codename: LASSO v1**

| Field | Value |
|---|---|
| Organization | Longhorn Silicon, UT Austin Cockrell School of Engineering |
| Classification | CONFIDENTIAL — Internal Use Only |
| Document Version | 2.0 (Prudent Revision) |
| Date | April 2026 |
| Target Tape-out | Fall 2027 shuttle submission, Spring 2028 silicon return |
| Process | SKY130 130nm via Efabless chipIgnite |
| Authors | Longhorn Silicon Architecture Team |

---

## How to Read This Document

This PRD is organized around a **must-ship baseline** and **stretch goals**. The baseline is what we commit to taping out. Stretch goals are additive blocks that get integrated ONLY if the baseline is verified and timing-closed ahead of schedule. This structure exists because the #1 risk to this project is not architecture quality — it's failing to tape out at all.

The companion document `../lasso-v0-original/PRD.md` (v1.0) contains the full 4-block LASSO vision. That document remains the long-term architecture target *for the SKY130 line*. This document is what was originally going to ship first on SKY130. Both are now archived: see `../lambda-v2/PRD.md` for the current TSMC 16nm direction.

---

## Table of Contents

1. [Scope Philosophy](#1-scope-philosophy)
2. [Must-Ship Baseline](#2-must-ship-baseline)
3. [Architecture Overview](#3-architecture-overview)
4. [Block 1: KV Cache Engine](#4-block-1-kv-cache-engine)
5. [Block 2: SRAM Buffer Controller](#5-block-2-sram-buffer-controller)
6. [Top-Level Integration](#6-top-level-integration)
7. [SRAM Subsystem](#7-sram-subsystem)
8. [Stretch Goal A: Token Importance Unit](#8-stretch-goal-a-token-importance-unit)
9. [Stretch Goal B: Dot-Product Scoring Unit](#9-stretch-goal-b-dot-product-scoring-unit)
10. [Stretch Goal C: DMA Engine](#10-stretch-goal-c-dma-engine)
11. [Verification Plan](#11-verification-plan)
12. [Physical Design Plan](#12-physical-design-plan)
13. [Timeline](#13-timeline)
14. [Risk Register](#14-risk-register)
15. [Success Criteria](#15-success-criteria)
16. [Team Structure](#16-team-structure)
17. [Reference Architecture](#17-reference-architecture)

---

## 1. Scope Philosophy

### The rule

**Every feature in the must-ship baseline must be verifiable by one person in under 4 weeks.** If a block requires more than 4 weeks of dedicated verification effort, it's either too complex for the baseline or it needs to be simplified until it isn't.

### Why

Student tapeout projects fail because of verification gaps and missed shuttle deadlines, not because the architecture was insufficiently clever. A 2-block chip that works is worth infinitely more than a 5-block chip that doesn't tape out. The architecture in the full PRD (v1.0) is the destination. This document is the vehicle that gets us there: a scoped, verifiable, tape-out-ready subset that proves the core thesis.

### The thesis we're proving

A purpose-built hardware block can quantize and dequantize KV cache vectors at wire speed with configurable 2-4 bit precision, store them in on-chip SRAM at 4-8x compression, and return reconstructed vectors on demand — all verified in silicon.

Everything else — token scoring, eviction policies, DMA, paged memory management, attention compute — can run in host software for v1 and be hardened into silicon in v2.

---

## 2. Must-Ship Baseline

The baseline chip has exactly two functional blocks plus SRAM:

| Block | Function | Complexity |
|---|---|---|
| **KV Cache Engine** | Quantize 16-bit → 2/3/4-bit INT, dequantize back, bit-pack/unpack | Medium (pipelined datapath, ~30 tests) |
| **SRAM Buffer Controller** | Wishbone slave interface, address decode, bank arbitration, CSRs | Low-Medium (~20 tests) |
| **SRAM Subsystem** | 4-8x CF_SRAM_16384x32 macros (256-512KB) | IP integration (pre-verified macro) |

**Total estimated verification: ~50-60 tests.** One person, 3-4 months. Achievable.

### What the baseline chip does (end-to-end)

1. Host writes a 16-bit KV vector to a LASSO address via Wishbone
2. KV Cache Engine quantizes it to the configured bit-width (2/3/4-bit)
3. Compressed data is stored in SRAM at a host-specified bank and address
4. Host reads from LASSO: compressed data is fetched from SRAM, dequantized to 16-bit, and returned
5. Host can also read/write raw compressed data directly (bypass mode) for manual cache management
6. Host can read/write SRAM directly without quantization (debug/calibration mode)

### What the host does in software (not in hardware for v1)

- Token importance scoring (host computes `abs(Q dot K)` after reading dequantized K)
- Eviction decisions (host decides which addresses to overwrite)
- Off-chip data movement (host reads compressed data from LASSO and writes to external memory)
- Address management (host maintains a software table mapping token IDs to SRAM addresses)
- Attention computation (host does full Q*K dot products)

This is a deliberate choice: **the hardware does the thing that must be fast (compression/decompression), and the host does everything that can tolerate software latency.**

---

## 3. Architecture Overview

```
                ┌────────────────────────────────────────┐
                │            LASSO v1 Top-Level            │
                │                                          │
  Wishbone B4   │  ┌──────────────────────────────────┐  │
  Slave ───────►│  │      SRAM Buffer Controller       │  │
  (Host)        │  │                                    │  │
                │  │  - Wishbone protocol handler       │  │
                │  │  - Address decode (bank select)    │  │
                │  │  - CSR register file               │  │
                │  │  - Mode select (quant/bypass/raw)  │  │
                │  │  - Interrupt controller (minimal)   │  │
                │  └──────────┬────────────┬───────────┘  │
                │             │            │               │
                │      ┌──────▼──────┐     │               │
                │      │  KV Cache   │     │               │
                │      │  Engine     │     │               │
                │      │            │     │               │
                │      │ - Quantize  │     │               │
                │      │ - DeQuant   │     │               │
                │      │ - Pack      │     │               │
                │      │ - Unpack    │     │               │
                │      └──────┬──────┘     │               │
                │             │            │               │
                │      ┌──────▼────────────▼───────────┐  │
                │      │       SRAM Subsystem           │  │
                │      │    4-8x CF_SRAM_16384x32       │  │
                │      │    (256-512 KB)                 │  │
                │      └───────────────────────────────┘  │
                │                                          │
                └──────────────────────────────────────────┘
```

### Data Paths

There are three data paths through the chip, selected by a CSR mode register:

**Path 1 — Quantized Write (primary):**
```
Host → Wishbone → Controller → KV Engine (quantize + pack) → SRAM
```

**Path 2 — Dequantized Read (primary):**
```
SRAM → KV Engine (unpack + dequantize) → Controller → Wishbone → Host
```

**Path 3 — Raw Bypass (debug/manual):**
```
Host → Wishbone → Controller → SRAM (no quantization)
```

That's it. Three paths, two blocks, one bus. Every path is testable by writing known data and reading it back.

---

## 4. Block 1: KV Cache Engine

### Purpose

The core IP of the chip. Hardware-accelerated quantization and dequantization of KV cache vectors. Converts 16-bit fixed-point KV data to 2-4 bit compressed format and back, at pipeline throughput.

### Functional Requirements

| ID | Requirement | Priority |
|---|---|---|
| KV-01 | Per-group symmetric quantization: 16-bit → configurable 2/3/4-bit INT | Must-have |
| KV-02 | Configurable group size: 32 or 64 elements | Must-have |
| KV-03 | Scale factor computation via shift-based approximation (no hardware divider) | Must-have |
| KV-04 | Dequantization: expand stored 2-4 bit values back to 16-bit fixed-point | Must-have |
| KV-05 | Bit-packing: pack N low-bit values into 32-bit words for SRAM storage | Must-have |
| KV-06 | Bit-unpacking: inverse of KV-05 | Must-have |
| KV-07 | Bypass mode: pass data through without transformation | Must-have |
| KV-08 | Scale factor stored alongside compressed data in SRAM (auto-managed) | Must-have |
| KV-09 | Asymmetric quantization mode (separate zero-point) via CSR | Should-have |
| KV-10 | Outlier detection: flag values above programmable threshold | Should-have |
| KV-11 | Separate K vs V quantization parameters | Should-have |
| KV-12 | Pipeline throughput: 1 group (32 elements) per 4 cycles at target clock | Must-have |

### Quantization Arithmetic

All formats are signed integer (INTn), not floating-point. See `../lasso-v0-original/design-rationale.md` for the INT4 vs FP4 decision.

```
Quantize:
  scale = max(abs(group)) >> (16 - b)       // shift-based approximation
  q[i]  = clamp(round(x[i] * recip_scale), -(2^(b-1)), 2^(b-1) - 1)

Dequantize:
  x_hat[i] = q[i] * scale                   // single multiply per element

Storage layout per group of 32 elements:
  [16-bit scale] [16-bit zero_point (if asymmetric)] [32 x b-bit packed values]
```

| Mode | Bits/element | Words per 32-element group (incl. scale) | Compression vs 16-bit |
|---|---|---|---|
| Q2 | 2 | 3 words (1 scale + 2 packed) | 5.3x |
| Q3 | 3 | 4 words (1 scale + 3 packed) | 4x |
| Q4 | 4 | 5 words (1 scale + 4 packed) | 3.2x |
| Bypass | 16 | 16 words | 1x |

### Microarchitecture

```
Pipeline Stage 1: Input Register + Group Buffer
  - Accept 32-bit Wishbone words, accumulate into 32-element group buffer
  - 16 Wishbone writes to fill one group (32 elements x 16-bit = 512 bits)

Pipeline Stage 2: Scale Computation
  - Tree reduction to find max(abs(group)) — 32-input, 5-level comparator tree
  - Compute scale factor via barrel shifter (shift-based reciprocal)
  - 1 cycle (combinational with output register)

Pipeline Stage 3: Quantize + Pack
  - 32 parallel multiply-shift units: x[i] * reciprocal_scale, then clamp
  - Bit-packer: assemble N-bit results into 32-bit words
  - 1 cycle

Pipeline Stage 4: Output Register
  - Quantized + packed words ready for SRAM write
  - Scale factor word prepended
  - Controller issues SRAM write sequence

Total pipeline: 4 stages, throughput = 1 group per 4 cycles after fill
Latency: 4 cycles for first output
```

Dequantization pipeline (reverse direction):

```
Stage 1: SRAM read — fetch scale word + packed data words
Stage 2: Unpack — extract N-bit values from 32-bit words
Stage 3: Dequant — 32 parallel: q[i] * scale (16-bit multiply)
Stage 4: Output — 16-bit results returned via Wishbone
```

### Interface

```verilog
module kv_cache_engine (
    input  wire        clk,
    input  wire        rst_n,

    // Configuration
    input  wire [1:0]  cfg_bit_width,       // 00=2, 01=3, 10=4, 11=bypass
    input  wire        cfg_group_size,      // 0=32, 1=64
    input  wire        cfg_asymmetric,      // enable zero-point
    input  wire [15:0] cfg_outlier_thresh,  // outlier detection threshold

    // Write path: raw 16-bit data in → compressed data out
    input  wire        wr_valid,
    output wire        wr_ready,
    input  wire [31:0] wr_data,            // 2x 16-bit elements per word
    output wire        wr_out_valid,
    input  wire        wr_out_ready,
    output wire [31:0] wr_out_data,        // packed compressed word
    output wire        wr_out_is_scale,    // 1 = this word is the scale factor

    // Read path: compressed data in → reconstructed 16-bit out
    input  wire        rd_valid,
    output wire        rd_ready,
    input  wire [31:0] rd_data,            // packed compressed word from SRAM
    input  wire        rd_is_scale,        // 1 = this word is the scale factor
    output wire        rd_out_valid,
    input  wire        rd_out_ready,
    output wire [31:0] rd_out_data         // 2x 16-bit reconstructed elements
);
```

### Area Estimate

| Component | Area |
|---|---|
| 32x comparators (max-abs tree) | ~0.005 mm² |
| Barrel shifter (reciprocal) | ~0.003 mm² |
| 32x 16-bit multiply-shift (quantize) | ~0.025 mm² |
| 32x 16-bit multipliers (dequantize) | ~0.025 mm² |
| Bit pack/unpack logic | ~0.005 mm² |
| Pipeline registers + control | ~0.007 mm² |
| **Total** | **~0.07 mm²** |

---

## 5. Block 2: SRAM Buffer Controller

### Purpose

Translates Wishbone bus transactions into KV Cache Engine operations and SRAM read/writes. Manages bank selection, addressing, mode control, and status reporting. This is deliberately simple: a state machine and an address decoder, not a memory management unit.

### Functional Requirements

| ID | Requirement | Priority |
|---|---|---|
| SC-01 | Wishbone B4 slave interface (single-cycle ACK for CSR, multi-cycle for data) | Must-have |
| SC-02 | Address decode: route to CSR space, SRAM banks, or KV Engine based on address | Must-have |
| SC-03 | Three operating modes: quantized, dequantized-read, raw bypass | Must-have |
| SC-04 | Bank select: upper address bits select which SRAM bank | Must-have |
| SC-05 | Byte-enable support (wbs_sel_i) for sub-word writes | Must-have |
| SC-06 | CSR register file: configuration, status, version, capability | Must-have |
| SC-07 | Interrupt output: operation complete, error | Must-have |
| SC-08 | Scan chain passthrough for SRAM testability | Must-have |
| SC-09 | Performance counters: cycles, groups compressed, groups decompressed | Should-have |
| SC-10 | Error detection: address out of range, bus protocol violation | Should-have |

### Address Map

| Address Range | Target | Access |
|---|---|---|
| 0x0000_0000 — 0x0000_00FF | CSR registers | R/W |
| 0x0001_0000 — 0x0001_FFFF | KV Engine write port (quantized write) | W only |
| 0x0002_0000 — 0x0002_FFFF | KV Engine read port (dequantized read) | R only |
| 0x0010_0000 — 0x0017_FFFF | SRAM Bank 0 (raw bypass) | R/W |
| 0x0018_0000 — 0x001F_FFFF | SRAM Bank 1 (raw bypass) | R/W |
| ... | ... | ... |
| 0x0048_0000 — 0x004F_FFFF | SRAM Bank 7 (raw bypass) | R/W |

The quantized write/read ports provide the primary interface: the host writes 16-bit data to the write port, the controller feeds it through the KV Engine, and stores the result at an auto-incrementing or CSR-specified SRAM address. On read, the reverse path dequantizes and returns data.

The raw bypass addresses let the host access SRAM directly for debug, calibration, or manual compressed-data management.

### CSR Registers

| Offset | Name | Description |
|---|---|---|
| 0x00 | CTRL | Mode select, enable, soft reset |
| 0x04 | STATUS | Busy, error flags, pipeline state |
| 0x08 | VERSION | Hardware version (read-only) |
| 0x0C | CAPABILITY | Supported bit-widths, bank count, max group size |
| 0x10 | TARGET_BANK | Which SRAM bank for next quantized write/read |
| 0x14 | TARGET_ADDR | Starting SRAM address for next operation |
| 0x18 | GROUP_COUNT | How many groups to process (batch operation) |
| 0x1C | IRQ_ENABLE | Interrupt enable mask |
| 0x20 | IRQ_STATUS | Interrupt status (W1C) |
| 0x24 | PERF_CYCLES | Cycle counter |
| 0x28 | PERF_GROUPS_WR | Groups quantized counter |
| 0x2C | PERF_GROUPS_RD | Groups dequantized counter |
| 0x30 | KV_BIT_WIDTH | Quantization config (mirrors KV Engine cfg) |
| 0x34 | KV_GROUP_SIZE | Group size config |
| 0x38 | KV_OUTLIER_TH | Outlier threshold |

### State Machine

The controller runs a simple 6-state FSM:

```
IDLE → RECV_GROUP → QUANTIZE → WRITE_SRAM → (repeat or DONE)
                                    ↕
IDLE → READ_SRAM → DEQUANTIZE → SEND_GROUP → (repeat or DONE)
                                    ↕
IDLE → RAW_ACCESS → (single SRAM read or write) → IDLE
```

No DMA, no page table, no multi-master arbitration. One operation at a time. Simple.

### Interface

```verilog
module sram_buffer_controller (
    input  wire        clk,
    input  wire        rst_n,

    // Wishbone B4 slave
    input  wire        wbs_cyc_i,
    input  wire        wbs_stb_i,
    input  wire        wbs_we_i,
    input  wire [3:0]  wbs_sel_i,
    input  wire [31:0] wbs_adr_i,
    input  wire [31:0] wbs_dat_i,
    output wire [31:0] wbs_dat_o,
    output wire        wbs_ack_o,
    output wire        wbs_err_o,

    // Interrupt
    output wire        irq,

    // KV Cache Engine
    // (directly wired, signals as per kv_cache_engine module)

    // SRAM banks (directly wired to macros)
    output wire [7:0]  sram_csb,
    output wire [7:0]  sram_web,
    output wire [13:0] sram_addr   [7:0],
    output wire [31:0] sram_din    [7:0],
    input  wire [31:0] sram_dout   [7:0],
    output wire [3:0]  sram_wmask  [7:0],

    // Scan chain passthrough
    input  wire        scan_en,
    input  wire        scan_in,
    output wire        scan_out
);
```

### Area Estimate

| Component | Area |
|---|---|
| Wishbone protocol logic | ~0.005 mm² |
| Address decoder | ~0.003 mm² |
| CSR register file (~15 registers) | ~0.005 mm² |
| FSM + control | ~0.005 mm² |
| Interrupt logic | ~0.002 mm² |
| **Total** | **~0.02 mm²** |

---

## 6. Top-Level Integration

### Top Module

```verilog
module lasso_top (
    input  wire        clk,
    input  wire        rst_n,

    // Wishbone B4 slave (external, connects to Caravel or host)
    input  wire        wbs_cyc_i,
    input  wire        wbs_stb_i,
    input  wire        wbs_we_i,
    input  wire [3:0]  wbs_sel_i,
    input  wire [31:0] wbs_adr_i,
    input  wire [31:0] wbs_dat_i,
    output wire [31:0] wbs_dat_o,
    output wire        wbs_ack_o,
    output wire        wbs_err_o,

    // Interrupt (active high)
    output wire        irq,

    // Scan chain
    input  wire        scan_en,
    input  wire        scan_in,
    output wire        scan_out
);
```

Internal wiring:
- `lasso_top` instantiates `sram_buffer_controller` and `kv_cache_engine`
- Controller drives KV Engine's configuration and data interfaces
- Controller drives all 4-8 SRAM macro instances
- Single clock domain, synchronous reset

### Integration Complexity

| Metric | Value |
|---|---|
| Total modules | 3 (top + controller + KV engine) + SRAM macros |
| Internal buses | 1 (controller ↔ KV engine, simple valid/ready) |
| Clock domains | 1 |
| State machines | 2 (controller FSM + KV engine pipeline control) |
| Interrupts | 1 output wire |
| External interfaces | 1 Wishbone slave |

This is deliberately minimal. Every signal is point-to-point. No crossbar, no arbiter, no bus matrix. If a signal is wrong, it's traceable to one of two modules.

---

## 7. SRAM Subsystem

### Using Existing IP

The [CF_SRAM_16384x32](https://github.com/LonghornSilicon/SRAM_16384x32) macro is the foundation. Each instance provides 64KB.

### Bank Configuration

| Config | Macros | Capacity | Area | Risk |
|---|---|---|---|---|
| **Minimum (fallback)** | 4 | 256 KB | ~4 mm² | Low — fits easily, more routing space |
| **Target** | 6 | 384 KB | ~5.5 mm² | Low-Medium |
| **Stretch** | 8 | 512 KB | ~7 mm² | Medium — tight on area with routing |

**Decision rule:** Start physical design with 4 macros. Add more only after DRC-clean placement of 4 macros is confirmed.

### What the SRAM Holds

At 4 banks (256KB), with the quantized storage format:

| Quantization | Bytes per group of 32 elements (incl. scale) | Groups in 256KB | Elements | Equivalent tokens (4-head, 128-dim) |
|---|---|---|---|---|
| Q2 | 12 bytes | ~21,845 | ~699K | ~1365 |
| Q4 | 20 bytes | ~13,107 | ~419K | ~819 |
| Bypass (16-bit) | 64 bytes | ~4,096 | ~131K | ~256 |

At Q2 with 4 banks: ~1365 tokens. At Q4: ~819 tokens. With 6 banks these numbers grow by 50%. Modest but meaningful for a proof-of-concept.

### Direct-Mapped Addressing (No Page Table)

SRAM banks are directly addressed. The host software maintains a mapping:

```
Host software data structure (NOT in hardware):
  token_map[sequence_id][token_id] = {
      bank: 0-7,
      addr: 0x0000-0x3FFF,
      bit_width: 2/3/4,
      is_key: bool
  }
```

When the host wants to store a new token's KV, it picks a free address from its software table. When it wants to evict, it marks the address free. LASSO hardware doesn't know or care about tokens — it just compresses what it receives and stores it where it's told.

This is simpler to verify, simpler to debug post-silicon, and functionally equivalent for characterization and demos. A hardware page table is a v2 feature.

---

## 8. Stretch Goal A: Token Importance Unit

**Include only if baseline verification completes before end of Spring 2027.**

A small sidecar block that accumulates per-token importance scores and provides a sorted ranking for the host to use in eviction decisions.

| Component | Description | Area |
|---|---|---|
| Score register file | 1024 x 16-bit entries (2KB, in SRAM partition) | Shared |
| Score accumulator | Adds incoming score to stored value | ~0.003 mm² |
| Min-K finder | 8-wide comparator tree, finds bottom-K entries | ~0.01 mm² |
| Control + CSR | Score read/write, trigger min-K search, results register | ~0.005 mm² |
| **Total** | | **~0.02 mm²** |

**Interface:** The host writes `{token_id, score_delta}` pairs. The unit accumulates. The host reads the bottom-K token IDs when it needs to decide evictions. All the policy intelligence stays in host software.

**Verification cost:** ~15-20 additional tests. One person, ~3 weeks.

**Why stretch, not baseline:** The host can do this in software with negligible performance impact. Scoring 1024 tokens in software on a 10MHz RISC-V takes ~5ms — acceptable for a characterization demo. Hardening it saves latency but doesn't change what the chip can demonstrate.

---

## 9. Stretch Goal B: Dot-Product Scoring Unit

**Include only if Stretch A is integrated and verified.**

A 32-wide multiply-accumulate unit for computing Q*K dot products directly on chip. Takes a Query from the host and compressed Key from SRAM, produces a 32-bit attention score.

| Component | Description | Area |
|---|---|---|
| 32x 16-bit multipliers | Element-wise Q*K multiply | ~0.04 mm² |
| Adder tree | 5-stage reduction, 32→1 | ~0.01 mm² |
| Accumulator | Running sum across chunks of a head | ~0.003 mm² |
| Control | Batch mode (iterate over stored tokens) | ~0.007 mm² |
| **Total** | | **~0.06 mm²** |

Supports two modes (CSR-selected):
- Mode A: dequantize K to 16-bit first, then 16x16 multiply (highest accuracy)
- Mode B: multiply 16-bit Q by 4-bit K directly, scale correction on final sum (smaller, faster)

**Verification cost:** ~15-20 additional tests. One person, ~3 weeks.

**Why stretch, not baseline:** The host can compute dot products in software. At 10MHz on a RISC-V core, a 128-dim dot product takes ~50us per token, so sweeping 1024 tokens takes ~50ms. Slow, but the chip's job is to prove the compression works — the dot-product accuracy can be verified by reading dequantized data and computing on the host.

---

## 10. Stretch Goal C: DMA Engine

**Include only if Stretches A and B are integrated and verified, AND physical design is on track.**

A simple descriptor-based DMA engine that can stream compressed data between on-chip SRAM and the external Wishbone master interface without host intervention.

This is the highest-risk stretch goal. DMA engines have complex corner cases (partial transfers, back-pressure, error recovery). Only include if the team has bandwidth and the shuttle deadline has >2 months of margin.

**Verification cost:** ~30-40 additional tests. One person, ~6-8 weeks.

**If DMA is not included:** The host manually reads compressed words from SRAM via Wishbone and writes them to external memory. Slower, but functionally identical.

---

## 11. Verification Plan

### Strategy

Two-level verification: unit tests per block, then system integration tests. All simulation-based (Verilator + cocotb).

### Golden Model

A Python reference implementation that is **the single source of truth**:

```
golden_model/
├── quantizer.py          # Bit-exact quantize/dequantize for all modes
├── bit_packer.py         # Pack/unpack logic matching hardware exactly
├── sram_model.py         # Behavioral SRAM model
└── lasso_system.py       # Full system: Wishbone transactions → expected SRAM contents
```

The golden model is developed FIRST, before any RTL. Every RTL test compares hardware output against golden model output, bit-for-bit.

### Test Plan — Baseline

| Category | Tests | Description | Owner |
|---|---|---|---|
| **KV Engine: Quantize** | 10 | All bit-widths, group sizes. Inputs: zeros, max, min, mixed, random | RTL Lead |
| **KV Engine: Dequant** | 8 | Round-trip accuracy for all modes. Verify error within expected bounds | RTL Lead |
| **KV Engine: Pack/Unpack** | 6 | Pack then unpack round-trip for Q2/Q3/Q4. Edge cases: all-same, alternating | RTL Lead |
| **KV Engine: Bypass** | 3 | Data passes through unchanged in bypass mode | RTL Lead |
| **KV Engine: Pipeline** | 3 | Back-to-back groups, pipeline stall/resume, flush | RTL Lead |
| **Controller: CSR** | 5 | Read/write all CSRs, verify reset values, read-only fields | Verification Lead |
| **Controller: Wishbone** | 8 | Single read, single write, back-to-back, byte enables, error on bad addr | Verification Lead |
| **Controller: Modes** | 3 | Switch between quantized/bypass/raw modes, verify correct routing | Verification Lead |
| **Controller: Bank select** | 4 | Write to each bank, read back, verify isolation | Verification Lead |
| **System: Round-trip** | 5 | Write raw KV via quantized port, read back via dequantized port, compare to golden model | Verification Lead |
| **System: Multi-group** | 3 | Write multiple groups sequentially, read back in different order | Verification Lead |
| **System: Mixed modes** | 3 | Interleave quantized writes with raw reads, verify consistency | Verification Lead |
| **Total baseline** | **~61** | | |

### Test Plan — Stretch Goals (if included)

| Category | Tests | Description |
|---|---|---|
| Token Importance: accumulate | 5 | Sequential scoring, overflow, reset |
| Token Importance: min-K | 5 | Find bottom-K with known scores, edge cases |
| Token Importance: integration | 5 | Score via system, read results |
| Dot-Product: accuracy | 8 | Known vectors, compare to golden model |
| Dot-Product: modes | 4 | Mode A vs B, verify both produce correct results |
| Dot-Product: batch | 3 | Sweep over N stored tokens |
| DMA: basic | 10 | Read, write, back-to-back |
| DMA: error | 5 | Incomplete transfer, back-pressure |
| DMA: integration | 5 | Full system with DMA moving data |

### CI Pipeline

- GitHub Actions on every push
- Verilator lint (warnings as errors)
- Full cocotb test suite with randomized seeds
- Coverage report (line + toggle + FSM state)
- Gate: no merge without 100% test pass

---

## 12. Physical Design Plan

### Toolchain

| Stage | Tool |
|---|---|
| Synthesis | Yosys + SKY130 liberty |
| Floorplan | OpenROAD (manual SRAM macro placement) |
| Placement | DREAMPlace |
| CTS | TritonCTS |
| Routing | TritonRoute |
| DRC/LVS | Magic + Netgen |
| STA | OpenSTA |
| GDSII export | Magic |
| Flow manager | OpenLane 2 |

### Floorplan (4-bank baseline)

```
┌──────────────────────────────────────┐
│             I/O Ring + Pads           │
│  ┌──────────────────────────────────┐│
│  │  ┌──────────┐  ┌──────────┐    ││
│  │  │ SRAM 0   │  │ SRAM 1   │    ││
│  │  │ (64KB)   │  │ (64KB)   │    ││
│  │  └──────────┘  └──────────┘    ││
│  │                                  ││
│  │  ┌──────────┐  ┌──────────┐    ││
│  │  │ SRAM 2   │  │ SRAM 3   │    ││
│  │  │ (64KB)   │  │ (64KB)   │    ││
│  │  └──────────┘  └──────────┘    ││
│  │                                  ││
│  │  ┌──────────────────────────┐   ││
│  │  │  KV Cache Engine         │   ││
│  │  │  + SRAM Buffer Controller│   ││
│  │  │  + Stretch blocks        │   ││
│  │  │  (all logic fits here)   │   ││
│  │  └──────────────────────────┘   ││
│  │                                  ││
│  └──────────────────────────────────┘│
│             I/O Ring + Pads           │
└──────────────────────────────────────┘
```

### Area Budget (4-bank baseline)

| Block | Area | % of 10mm² |
|---|---|---|
| SRAM (4x CF_SRAM_16384x32) | 3.5 mm² | 35% |
| KV Cache Engine | 0.07 mm² | 0.7% |
| SRAM Buffer Controller | 0.02 mm² | 0.2% |
| Stretch A (Token Importance) | 0.02 mm² | 0.2% |
| Stretch B (Dot-Product) | 0.06 mm² | 0.6% |
| I/O pads + pad ring | 1.5 mm² | 15% |
| Routing + fill + clock tree | 1.5 mm² | 15% |
| **Subtotal** | **~6.7 mm²** | **67%** |
| **Remaining (for more SRAM or margin)** | **~3.3 mm²** | **33%** |

With 4 banks, there's 3.3mm² of headroom. That's enough for 2-4 more SRAM macros, generous routing channels, and all three stretch blocks. The baseline is not area-constrained. This is a feature, not a waste — margin is what saves you during physical design.

### Timing Target

| Parameter | Target |
|---|---|
| Clock frequency | 50 MHz (20ns period) |
| Critical path | SRAM read → dequant multiply → Wishbone data out |
| Strategy | Pipeline register between SRAM read and KV Engine input |
| Fallback | 25 MHz if timing closure is difficult (40ns gives 4x margin on SRAM read) |

---

## 13. Timeline

```
2026
────────────────────────────────────────────────────────────
Apr-May     ▓▓▓▓▓  PRD finalization, team recruitment, tool setup

Jun-Aug     ▓▓▓▓▓▓▓▓▓  PHASE 0: Foundation
            ├─ Golden model (Python): ALL quantization modes, bit-exact
            ├─ CF_SRAM_16384x32 validated in OpenLane (standalone PnR)
            ├─ Verilator + cocotb CI pipeline operational
            └─ Test vector generation from real model KV dumps

Sep-Nov     ▓▓▓▓▓▓▓▓▓▓  PHASE 1: KV Cache Engine RTL + Verification
            ├─ KV Engine RTL: quantize, dequant, pack, unpack, bypass
            ├─ Unit tests: all 30 KV Engine tests passing
            └─ MILESTONE: KV Engine verified against golden model ✓

Dec         ▓▓▓▓  PHASE 1b: Controller + Integration
            ├─ SRAM Buffer Controller RTL
            ├─ Top-level integration (2 blocks + SRAM stubs)
            └─ System-level tests: round-trip quantize/dequantize

2027
────────────────────────────────────────────────────────────
Jan-Feb     ▓▓▓▓▓▓▓  PHASE 2: System Verification + SRAM Integration
            ├─ Replace SRAM stubs with real CF_SRAM_16384x32 macros
            ├─ Full system test suite (61 tests) passing
            └─ MILESTONE: RTL FREEZE for baseline ✓

Mar-Apr     ▓▓▓▓▓▓▓  STRETCH WINDOW
            ├─ IF AHEAD: integrate Token Importance Unit
            ├─ IF AHEAD: integrate Dot-Product Scoring Unit
            └─ IF AHEAD: integrate DMA Engine
            Any stretch blocks must be verified by end of April.

May-Jun     ▓▓▓▓▓▓▓  PHASE 3a: Synthesis + Floorplan
            ├─ Yosys synthesis, initial area/timing report
            ├─ SRAM macro placement in OpenROAD
            ├─ Initial place-and-route
            └─ DECISION: how many SRAM banks fit? Finalize bank count.

Jul-Sep     ▓▓▓▓▓▓▓▓▓▓  PHASE 3b: Physical Design Iteration
            ├─ PnR iterations targeting timing closure
            ├─ DRC/LVS clean
            ├─ Clock tree synthesis and optimization
            └─ MILESTONE: timing closure at target frequency ✓

Oct-Nov     ▓▓▓▓▓▓▓  PHASE 3c: Signoff
            ├─ Gate-level simulation (full test suite on post-PnR netlist)
            ├─ Final DRC/LVS
            ├─ IR drop analysis (if time permits)
            ├─ GDSII generation
            └─ MILESTONE: GDSII submitted to Efabless ✓

2028
────────────────────────────────────────────────────────────
Jan-Feb     ░░░░░░░░  Fab turnaround

Mar-May     ▓▓▓▓▓▓▓▓▓▓  PHASE 4: Bring-up + Demo
            ├─ SRAM self-test via scan chain
            ├─ Wishbone alive check (CSR read/write)
            ├─ Functional test: quantize/dequantize round-trip
            ├─ Characterization: compression ratio, accuracy, throughput
            ├─ Demo: compress real model KV cache, show accuracy
            └─ Technical report / workshop paper submission
```

### Key Milestones

| Date | Milestone | Go/No-Go Criteria |
|---|---|---|
| Aug 2026 | Golden model complete | All quant modes produce correct output on real KV data |
| Aug 2026 | SRAM macro validated | Standalone OpenLane synthesis + PnR, DRC clean |
| Nov 2026 | KV Engine verified | All 30 unit tests passing against golden model |
| Feb 2027 | RTL freeze (baseline) | Full 61-test suite passing, no open bugs |
| Apr 2027 | Stretch window closes | Any stretch blocks either verified or cut |
| Jun 2027 | First synthesis | Area and timing estimates validated |
| Sep 2027 | Timing closure | All paths meet 50MHz (or fallback) |
| Nov 2027 | GDSII submitted | DRC/LVS clean, gate-level sim passing |
| Apr 2028 | Silicon demo | Functional chip |

---

## 14. Risk Register

| ID | Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| R-01 | KV Engine quantization has subtle accuracy bugs | Medium | High | Golden model developed FIRST; bit-exact comparison on every test |
| R-02 | SRAM macro doesn't meet timing at 50MHz | Medium | Medium | Fallback to 25MHz; add pipeline register between SRAM and logic |
| R-03 | 4 SRAM macros cause routing congestion | Low | Medium | Conservative floorplan with wide routing channels; 3.3mm² headroom |
| R-04 | Efabless shuttle schedule slips | Low | Critical | Track chipIgnite dates quarterly; Tiny Tapeout as backup vehicle |
| R-05 | Team attrition | Medium | High | Modular design: each block owned by one person, documented, cross-trained |
| R-06 | Stretch blocks break baseline | Medium | High | Stretch blocks are NEVER merged to main branch until independently verified |
| R-07 | Post-silicon SRAM yield | Medium | Medium | Scan chain enables SRAM self-test as first bring-up step |
| R-08 | Scope creep | High | High | This document is the scope. The stretch window has a hard close date (Apr 2027) |
| R-09 | Wishbone protocol compliance | Low | Medium | Use proven Wishbone B4 BFM from cocotb-bus for testing |
| R-10 | OpenLane flow issues with SRAM macros | Medium | Medium | Validate SRAM in OpenLane FIRST (Phase 0, Summer 2026) |

---

## 15. Success Criteria

### Must Achieve (ALL required for project success)

1. GDSII submitted to Efabless by Nov 2027
2. DRC and LVS signoff clean
3. Gate-level simulation passes full baseline test suite
4. KV Engine correctly quantizes and dequantizes at 2-bit and 4-bit (verified in gate-level sim)
5. Wishbone interface functional (host can write raw data, read compressed data, read decompressed data)
6. Scan chain operational
7. At least 4 SRAM banks (256KB) integrated

### Target (aim for all, acceptable to miss 1-2)

8. 50 MHz clock achieved (vs 25 MHz fallback)
9. 6+ SRAM banks integrated (384KB+)
10. 3-bit quantization mode functional
11. Outlier detection functional
12. Performance counters reporting correct values

### Stretch (bonus, not expected)

13. Token Importance Unit integrated and verified
14. Dot-Product Scoring Unit integrated and verified
15. DMA Engine integrated and verified
16. Silicon returns functional (SRAM self-test passes)
17. Live demo compressing real model KV data on returned silicon
18. Workshop paper accepted

### What success looks like

| If we achieve... | The outcome is... |
|---|---|
| Must-have only | We taped out a working KV compression engine. Publishable, demonstrable, team has full-flow experience. **This is a successful project.** |
| Must-have + targets | Above, plus the chip runs faster and holds more data. Better demo, stronger paper. |
| Must-have + targets + stretches | We shipped most of the full LASSO vision on the first try. Exceptional outcome. |
| Must-have fails | We have verified RTL and a GDSII that didn't pass signoff. Painful but the RTL and golden model are still reusable. The org can try again next shuttle. |

---

## 16. Team Structure

| Role | Count | Owns | Baseline Load |
|---|---|---|---|
| Architecture Lead | 1 | This PRD. Golden model. Architecture decisions. | Phase 0 heavy, then advisory |
| RTL Lead | 1 | KV Cache Engine RTL. Top-level integration. | Phase 1-2 heavy |
| RTL/Verification | 1 | SRAM Buffer Controller RTL. Cocotb test suite. CI pipeline. | Phase 1-2 heavy |
| Physical Design Lead | 1 | OpenLane flow. Floorplan. Timing closure. GDSII. | Phase 0 (SRAM validation), then Phase 3 heavy |
| Flex (RTL or PD) | 0-2 | Stretch goal blocks OR PD support depending on schedule | Phase 2-3 |

**Minimum viable team: 4 people.** The architecture lead and RTL lead can overlap if needed (one person doing both), but verification and physical design must be separate people — you cannot objectively verify your own RTL, and PD is a full-time job during Phase 3.

---

## 17. Reference Architecture

| Reference | Relevance | What We Take From It |
|---|---|---|
| **Titanus** (GLSVLSI'25) | Highest | Cascade pruning+quantization co-design; validates KV compression in ASIC |
| **RotateKV** (AAAI'25) | High | 2-bit INT quantization achieves <0.3 PPL degradation; validates our Q2 mode |
| **GEAR** (ArXiv'24) | High | Simple quantization gets most of the compression benefit; complex schemes have diminishing returns |
| **MiKV** (ArXiv'24) | Medium | Mixed-precision cache is better than full eviction; informs stretch goal A |
| **TurboQuant** (Google, 2026) | Medium | PolarQuant is a v2 target; validates the importance of KV compression |
| **CF_SRAM_16384x32** | Critical | Our on-chip memory foundation; already on GitHub, OpenLane-compatible |
| **T1C** (open source) | Medium | Another open-source LLM accelerator on SKY130; potential for shared learnings |

### Companion Documents

- `../lasso-v0-original/PRD.md` (v1.0) — Full 4-block LASSO vision (long-term architecture target)
- `../lasso-v0-original/design-rationale.md` — Detailed reasoning behind every architectural decision
- `arch-ref.md` — Research bibliography and literature analysis (not in repo)
- `polar-quant-comp.md` — PolarQuant compression mechanics deep-dive (not in repo)
- `prev-idea.md` — Earlier architecture candidates (eliminated; see ../lasso-v0-original/design-rationale.md)

**Note (2026-04-26 reorg):** This document was moved from the repo root into `PRDs/lasso-v1-prudent/`. Relative references above are updated. The current ACTIVE chip target is `../lambda-v2/PRD.md` (TSMC 16nm); LASSO PRDs are archived for inheritance reference (KCE block + research narrative carry forward).

---

*Ship the baseline. Stretch if you can. Tape out no matter what.*
