# Longhorn Silicon — Product Requirements Document

**KV Cache Compression Coprocessor for LLM Inference**

**Codename: LASSO** (Longhorn Accelerator for Storage-Side Optimization)

| Field | Value |
|---|---|
| Organization | Longhorn Silicon, UT Austin Cockrell School of Engineering |
| Classification | CONFIDENTIAL — Internal Use Only |
| Document Version | 1.0 |
| Date | April 2026 |
| Target Tape-out | Spring 2028 (Efabless chipIgnite, SKY130 130nm) |
| Authors | Longhorn Silicon Architecture Team |

---

## Table of Contents

1. [Problem Statement](#1-problem-statement)
2. [Product Vision & Positioning](#2-product-vision--positioning)
3. [Design Constraints & Boundary Conditions](#3-design-constraints--boundary-conditions)
4. [Architecture Overview](#4-architecture-overview)
5. [Block 1: KV Cache Engine](#5-block-1-kv-cache-engine)
6. [Block 2: Token Importance Unit](#6-block-2-token-importance-unit)
7. [Block 3: Memory Hierarchy Controller](#7-block-3-memory-hierarchy-controller)
8. [Block 4: Lightweight Attention Compute Unit](#8-block-4-lightweight-attention-compute-unit)
9. [Top-Level Integration & Interfaces](#9-top-level-integration--interfaces)
10. [SRAM Subsystem & Existing IP](#10-sram-subsystem--existing-ip)
11. [Quantization Strategy](#11-quantization-strategy)
12. [Verification Plan](#12-verification-plan)
13. [Physical Design Plan](#13-physical-design-plan)
14. [Risk Register](#14-risk-register)
15. [Phased Delivery & Scope Cuts](#15-phased-delivery--scope-cuts)
16. [Timeline](#16-timeline)
17. [Team Structure & Ownership](#17-team-structure--ownership)
18. [Success Criteria](#18-success-criteria)
19. [Reference Architecture & Prior Art](#19-reference-architecture--prior-art)
20. [Glossary](#20-glossary)

---

## 1. Problem Statement

Modern large language model (LLM) inference is memory-bound, not compute-bound. During autoregressive decoding, each new token requires reading the full Key-Value (KV) cache from memory, performing a dot-product attention computation, and writing updated state back. For a model like Qwen3-8B, the KV cache alone can exceed 32MB at modest context lengths — far beyond what on-chip SRAM can hold.

The result: inference throughput is gated by memory bandwidth. GPUs waste enormous energy and die area on general-purpose compute that sits idle during decode, while the memory bus saturates.

**The opportunity:** a purpose-built coprocessor that compresses, manages, and streams KV cache data can break the memory wall without needing a general-purpose compute fabric. Industry is converging on this insight:

- **Titanus** (UVA, GLSVLSI'25): 159.9x energy efficiency over A100 via cascade pruning + quantization of KV cache on-the-fly
- **Taalas HC1** (Feb 2026): 17,000 tok/s by hardwiring Llama 3.1 8B, eliminating memory fetch entirely
- **NVIDIA Vera Rubin** (GTC'26): 3-4x throughput via on-die CG-HBM memory stacking
- **TurboQuant** (Google, Mar 2026): 3-bit KV quantization with zero accuracy loss, no retraining

Every one of these is a bet that memory architecture, not FLOPS, determines inference performance.

Longhorn Silicon's thesis: **we can build a proof-of-concept KV cache compression coprocessor on the open-source SKY130 process that demonstrates the core datapath — compress, score, evict, stream — and publish the first fully open-source silicon implementation of this emerging architecture class.**

---

## 2. Product Vision & Positioning

### What LASSO Is

A digital ASIC coprocessor that sits between a host processor and off-chip DRAM, managing the KV cache for LLM inference workloads. It receives uncompressed KV vectors, quantizes them to 2-4 bits, scores tokens for importance, evicts low-value entries, and streams compressed data to/from external memory.

### What LASSO Is Not

- Not a standalone LLM inference engine (no weight storage, no full attention, no MLP)
- Not a GPU replacement
- Not an analog or mixed-signal design
- Not a commercial product (it is a research tapeout and proof-of-concept)

### Positioning

| Audience | Value Proposition |
|---|---|
| Academic reviewers | First open-source KV cache compression coprocessor taped out on SKY130; publishable at ISSCC/VLSI/MICRO workshops |
| Faculty advisors | Touches system-level architecture (Gerstlauer), physical design (Pan), memory systems (John) |
| Industry sponsors | Demonstrates understanding of the inference memory bottleneck with working silicon |
| Recruiting pipeline | Students graduate with tapeout experience on a problem that matters to every AI chip company |
| Open-source community | Fully open RTL + OpenLane flow; reusable SRAM macros and compression IP |

---

## 3. Design Constraints & Boundary Conditions

### Process & Fabrication

| Parameter | Constraint |
|---|---|
| Process | SkyWater SKY130 (130nm) via Efabless chipIgnite |
| Die Area Budget | ~10 mm² usable (chipIgnite standard slot) |
| SRAM Density | ~0.1-0.2 MB/mm² at 130nm |
| Max On-chip SRAM | ~1-2 MB (area-limited); baseline target 512KB (8x CF_SRAM_16384x32 = 512KB) |
| Target Clock | 50-100 MHz (conservative for 130nm, timing closure friendly) |
| Supply Voltage | 1.8V (SKY130 nominal) |
| EDA Toolchain | OpenROAD (Yosys synthesis, OpenSTA timing, DREAMPlace, TritonRoute) |
| Shuttle Cost | ~$10,000-$15,000 per chipIgnite slot |
| I/O | Wishbone B4 bus (compatible with Caravel harness) or custom streaming interface |

### Operational Constraints

| Parameter | Constraint |
|---|---|
| Team Size | 4-6 students (2-3 RTL/verification, 1-2 physical design, 1 architecture/research) |
| Development Time | ~18 months from architecture freeze to tapeout submission |
| Verification | Simulation-only (Verilator + cocotb); no FPGA prototyping required but encouraged |
| IP Dependencies | CF_SRAM_1024x32 (base macro), CF_SRAM_16384x32 (already on GitHub) |

### Design Rules

- **All digital.** No analog blocks, no custom sense amps beyond what the SRAM compiler provides.
- **No floating-point datapaths.** All arithmetic is fixed-point or integer.
- **Wishbone B4 compliance** for host interface (Caravel compatibility).
- **Scan chain insertion** for post-silicon testability.

---

## 4. Architecture Overview

LASSO comprises four functional blocks plus a top-level controller, connected by an internal data bus. The design is a streaming pipeline: KV vectors enter from the host, get compressed and scored, and exit to off-chip memory in compressed form.

```
                    ┌─────────────────────────────────────────────────┐
                    │                 LASSO Top-Level                  │
                    │                                                  │
   Host Bus ───────┤►  ┌──────────────┐    ┌──────────────────────┐  │
  (Wishbone)       │   │  KV Cache     │    │  Token Importance    │  │
                   │   │  Engine       │◄──►│  Unit                │  │
                   │   │              │    │                      │  │
                   │   │  - Quantizer  │    │  - Score accumulator │  │
                   │   │  - DeQuant    │    │  - Comparator tree   │  │
                   │   │  - Pack/Unpack│    │  - Eviction policy   │  │
                   │   └──────┬───────┘    └──────────┬───────────┘  │
                   │          │                       │               │
                   │          ▼                       ▼               │
                   │   ┌──────────────────────────────────────────┐  │
                   │   │       Memory Hierarchy Controller         │  │
                   │   │                                           │  │
                   │   │  - SRAM buffer mgr (CF_SRAM_16384x32)    │  │
                   │   │  - Page table / tag store                 │  │
                   │   │  - DMA engine for off-chip streaming      │  │
                   │   │  - Compressed write-back path             │  │
                   │   └──────────────────────────────────────────┘  │
                   │          │                                       │
                   │          ▼                                       │
                   │   ┌──────────────────────────────────────────┐  │
                   │   │    Lightweight Attention Compute Unit     │  │
                   │   │    (v1: token scoring dot-product only)   │  │
                   │   └──────────────────────────────────────────┘  │
                   │                                                  │
                   └──────────────────────────┬───────────────────────┘
                                              │
                                    Off-chip DRAM Interface
```

### Data Flow (Encode Path — Prefill/New Token Arrival)

1. Host writes raw 16-bit KV vector to LASSO via Wishbone
2. **KV Cache Engine** quantizes the vector to target bit-width (2-4 bit)
3. **Token Importance Unit** scores the incoming token (partial dot-product with running query state) and assigns an importance tag
4. **Memory Hierarchy Controller** decides placement: high-importance tokens go to SRAM at full/high precision, low-importance tokens get aggressively compressed and streamed to off-chip
5. Compressed, tagged entry is written to SRAM buffer or DMA'd to external memory

### Data Flow (Decode Path — Attention Read)

1. Host sends current Query vector
2. **Memory Hierarchy Controller** fetches relevant KV entries from SRAM (and optionally triggers DMA prefetch from off-chip for evicted tokens)
3. **KV Cache Engine** dequantizes fetched entries to working precision
4. **Lightweight Attention Compute Unit** computes Q*K dot products for a tile of tokens, returns attention scores to host
5. Host uses scores for softmax and V weighting (or LASSO performs partial V accumulation if area permits)

---

## 5. Block 1: KV Cache Engine

### Purpose

Hardware-accelerated quantization and dequantization of KV cache vectors. This is the core value proposition of the chip: converting 16-bit KV vectors to 2-4 bit compressed representations with minimal accuracy loss, at wire speed.

### Functional Requirements

| ID | Requirement | Priority |
|---|---|---|
| KV-01 | Symmetric uniform quantization of 16-bit input to configurable 2/3/4-bit output | Must-have |
| KV-02 | Per-channel or per-group scale factor computation (group size configurable: 32/64/128) | Must-have |
| KV-03 | Asymmetric quantization mode (separate zero-point) via CSR configuration | Should-have |
| KV-04 | Dequantization: expand 2-4 bit stored values back to 16-bit fixed-point for compute | Must-have |
| KV-05 | Bit-packing unit: pack N low-bit values into 32-bit words for SRAM storage | Must-have |
| KV-06 | Bit-unpacking unit: inverse of KV-05 | Must-have |
| KV-07 | Outlier detection: flag values exceeding a programmable threshold for special handling | Should-have |
| KV-08 | Support separate quantization parameters for Keys vs Values (asymmetric K/V) | Should-have |
| KV-09 | Throughput: sustain 1 vector (e.g., 32 elements) per cycle at target clock | Must-have |
| KV-10 | Bypass mode: pass-through without quantization for debugging/calibration | Must-have |

### Microarchitecture

```
Input (16-bit x 32 elements)
        │
        ▼
┌───────────────┐
│ Scale Compute  │  ── Find min/max over group, compute scale = (max-min)/(2^b - 1)
│ (pipelined)    │     Uses shift-based division approximation, not full divider
└───────┬───────┘
        │
        ▼
┌───────────────┐
│ Quantize Array │  ── 32 parallel: round((x - zero_point) / scale)
│ (32-wide)      │     Implemented as multiply-shift (scale reciprocal precomputed)
└───────┬───────┘
        │
        ▼
┌───────────────┐
│ Outlier Check  │  ── Compare against threshold; outliers get separate treatment
│ & Tag          │     (stored at higher precision in reserved SRAM region)
└───────┬───────┘
        │
        ▼
┌───────────────┐
│ Bit Packer     │  ── Pack 32 x N-bit values into 32-bit words
│                │     At 4-bit: 8 values per word → 4 words out
│                │     At 2-bit: 16 values per word → 2 words out
└───────┬───────┘
        │
        ▼
  To Memory Hierarchy Controller
```

### Dequantization Path (reverse)

```
From Memory Hierarchy Controller
        │
        ▼
┌───────────────┐
│ Bit Unpacker   │
└───────┬───────┘
        │
        ▼
┌───────────────┐
│ DeQuant Array  │  ── 32 parallel: x_hat = quant_val * scale + zero_point
│ (32-wide)      │
└───────┬───────┘
        │
        ▼
  To Attention Compute or Host
```

### Key Design Decisions

- **Why not PolarQuant?** PolarQuant (the tree-of-angles scheme from TurboQuant) requires CORDIC or large sin/cos LUTs for reconstruction. At 130nm, the area cost is prohibitive for v1. Linear quantization (RotateKV-style) achieves <0.3 PPL degradation at 2-bit and requires only multipliers and shifters. PolarQuant is a v2 research target.
- **Why configurable bit-width?** Different models and different layers benefit from different precision. The KV-cache engine should support 2, 3, and 4-bit modes selected via a configuration register, allowing runtime experimentation.
- **Division approximation:** Scale factor computation avoids a hardware divider (expensive at 130nm). Instead, we precompute the reciprocal of (max-min) using a shift-and-add approximation or a small LUT, then multiply.

### Interface Signals

```verilog
module kv_cache_engine (
    input  wire        clk,
    input  wire        rst_n,

    // Configuration (memory-mapped CSR)
    input  wire [1:0]  cfg_bit_width,      // 00=2bit, 01=3bit, 10=4bit, 11=bypass
    input  wire [1:0]  cfg_group_size,     // 00=32, 01=64, 10=128
    input  wire        cfg_asymmetric,     // 1=asymmetric (use zero-point)
    input  wire [15:0] cfg_outlier_thresh, // outlier detection threshold

    // Input: raw KV vector from host
    input  wire        in_valid,
    output wire        in_ready,
    input  wire [511:0] in_data,           // 32 x 16-bit elements
    input  wire        in_is_key,          // 0=value, 1=key

    // Output: compressed KV to memory controller
    output wire        out_valid,
    input  wire        out_ready,
    output wire [127:0] out_data,          // packed compressed data (width varies)
    output wire [15:0] out_scale,          // scale factor for this group
    output wire [15:0] out_zero_point,     // zero-point (if asymmetric)
    output wire [3:0]  out_outlier_mask,   // which elements are outliers

    // Dequant input: compressed KV from memory controller
    input  wire        dq_in_valid,
    output wire        dq_in_ready,
    input  wire [127:0] dq_in_data,
    input  wire [15:0] dq_in_scale,
    input  wire [15:0] dq_in_zero_point,

    // Dequant output: reconstructed 16-bit vector
    output wire        dq_out_valid,
    input  wire        dq_out_ready,
    output wire [511:0] dq_out_data        // 32 x 16-bit reconstructed
);
```

### Area Estimate

- 32 parallel 16-bit multipliers (quantize/dequant): ~0.05 mm² at 130nm
- Min/max tree (32-input): ~0.005 mm²
- Packing/unpacking logic: ~0.005 mm²
- Control + CSRs: ~0.005 mm²
- **Total estimate: ~0.07 mm²** (well within budget)

---

## 6. Block 2: Token Importance Unit

### Purpose

Scores incoming tokens based on estimated attention weight contribution and drives cache eviction/retention policy. This implements the core insight from MiKV ("No Token Left Behind") and BalanceKV: not all tokens in the KV cache deserve equal treatment. Important tokens get retained at higher precision; unimportant ones get aggressively compressed or evicted.

### Functional Requirements

| ID | Requirement | Priority |
|---|---|---|
| TI-01 | Accumulate per-token importance score across layers/heads | Must-have |
| TI-02 | Score metric: running sum of partial attention weights (approximated via Q*K dot product magnitude) | Must-have |
| TI-03 | Maintain a sorted or heap-based index of N tokens ranked by importance | Must-have |
| TI-04 | Eviction trigger: when SRAM buffer exceeds configurable watermark, evict lowest-scored tokens | Must-have |
| TI-05 | Eviction action: lowest-scored tokens are compressed to minimum bit-width and DMA'd to off-chip | Must-have |
| TI-06 | Retention action: highest-scored tokens remain in SRAM at configured precision | Must-have |
| TI-07 | Configurable eviction policy: bottom-K eviction, or probabilistic sampling (BalanceKV-inspired) | Should-have |
| TI-08 | "Attention sink" protection: first N tokens (configurable) are never evicted (attention sink phenomenon) | Must-have |
| TI-09 | Score decay: optionally apply exponential decay to older scores (recency bias) | Could-have |
| TI-10 | Expose score array to host for debugging/analysis via CSR read | Should-have |

### Microarchitecture

```
From Attention Compute (partial Q*K scores)
        │
        ▼
┌───────────────────┐
│ Score Accumulator  │  ── Per-token register file (or SRAM-backed for large token counts)
│ (N entries x 16b)  │     score[token_id] += abs(qk_partial)
└───────┬───────────┘
        │
        ▼
┌───────────────────┐
│ Comparator Tree    │  ── Find bottom-K tokens when eviction triggered
│ (pipelined merge   │     8-wide comparator network, log(N) stages
│  sort or min-heap) │
└───────┬───────────┘
        │
        ▼
┌───────────────────┐
│ Eviction Controller│  ── Generates eviction commands to Memory Hierarchy Controller
│                    │     Commands: {token_id, action: EVICT | COMPRESS | RETAIN}
└───────┬───────────┘
        │
        ▼
  To Memory Hierarchy Controller
```

### Capacity & Sizing

At 130nm, maintaining per-token scores in registers is feasible for modest context lengths:

| Context Length | Score Store Size (16-bit per token) | Storage |
|---|---|---|
| 256 tokens | 256 x 16 bits | 512 bytes (registers) |
| 1024 tokens | 1024 x 16 bits | 2 KB (small SRAM) |
| 4096 tokens | 4096 x 16 bits | 8 KB (SRAM-backed) |

For v1, targeting 1024-token context is realistic. Score storage can share a partition of the existing SRAM subsystem.

### Interface Signals

```verilog
module token_importance_unit (
    input  wire        clk,
    input  wire        rst_n,

    // Configuration
    input  wire [9:0]  cfg_max_tokens,       // max tokens to track (up to 1024)
    input  wire [9:0]  cfg_watermark,        // eviction trigger threshold
    input  wire [3:0]  cfg_sink_count,       // attention sink protection (first N tokens)
    input  wire [1:0]  cfg_evict_policy,     // 00=bottom-K, 01=probabilistic
    input  wire [7:0]  cfg_evict_count,      // how many to evict per trigger

    // Score input (from attention compute)
    input  wire        score_valid,
    input  wire [9:0]  score_token_id,
    input  wire [15:0] score_value,          // abs(Q*K) partial score

    // Current occupancy
    input  wire [9:0]  current_token_count,

    // Eviction commands out
    output wire        evict_valid,
    input  wire        evict_ready,
    output wire [9:0]  evict_token_id,
    output wire [1:0]  evict_action,         // 00=evict, 01=compress, 10=retain

    // Debug: read score array
    input  wire [9:0]  dbg_read_addr,
    output wire [15:0] dbg_read_data
);
```

### Area Estimate

- Score SRAM (2KB for 1024 tokens): shared with main SRAM subsystem
- 8-wide comparator tree: ~0.01 mm²
- Control logic: ~0.005 mm²
- **Total estimate: ~0.02 mm²** (plus shared SRAM)

---

## 7. Block 3: Memory Hierarchy Controller

### Purpose

Orchestrates all data movement between the on-chip SRAM buffer, the KV Cache Engine, the Token Importance Unit, and the off-chip DRAM interface. Implements paged KV cache management inspired by vLLM's PagedAttention, adapted for hardware.

This is the "traffic cop" of the chip. It decides where data lives, when it moves, and in what form.

### Functional Requirements

| ID | Requirement | Priority |
|---|---|---|
| MH-01 | Manage on-chip SRAM as a paged buffer: fixed-size pages (e.g., 256B) with a page table | Must-have |
| MH-02 | Page table: maps {sequence_id, token_id} → {sram_page, precision, valid} | Must-have |
| MH-03 | Allocate pages for incoming tokens; reclaim pages on eviction | Must-have |
| MH-04 | DMA engine: stream compressed KV to off-chip via a simple serial/parallel interface | Must-have |
| MH-05 | DMA prefetch: anticipatory read-ahead of evicted tokens from off-chip (host-triggered) | Should-have |
| MH-06 | Double-buffering: allow one SRAM bank to serve reads while another absorbs writes | Must-have |
| MH-07 | Mixed-precision storage: store high-importance tokens at 4-bit, low-importance at 2-bit | Should-have |
| MH-08 | Compressed write-back: only write non-zero, quantized data to off-chip (Titanus CPQ-inspired) | Must-have |
| MH-09 | Sequence management: support at least 4 concurrent sequences (batch inference) | Should-have |
| MH-10 | Memory-mapped status registers: occupancy, page utilization, DMA status | Must-have |
| MH-11 | Wishbone slave interface for host access to SRAM contents | Must-have |
| MH-12 | Wishbone master interface for off-chip DMA | Must-have |

### SRAM Organization (using existing IP)

The chip instantiates multiple CF_SRAM_16384x32 macros. Each provides 64KB (16384 words x 32 bits).

| Configuration | Macro Count | Total Capacity | Estimated Area |
|---|---|---|---|
| Minimal (v1-safe) | 4x CF_SRAM_16384x32 | 256 KB | ~4 mm² |
| Target (v1) | 8x CF_SRAM_16384x32 | 512 KB | ~6-7 mm² |
| Stretch (if area permits) | 12x CF_SRAM_16384x32 | 768 KB | ~8-9 mm² |

Each macro is internally composed of 16x CF_SRAM_1024x32 sub-macros in a 2-column x 8-row layout.

### Page Table Design

```
Page size: 256 bytes (64 x 32-bit words)
Pages per 64KB macro: 256
Total pages (8 macros): 2048

Page Table Entry (PTE): 32 bits
  [31]    valid
  [30]    dirty
  [29:28] precision (00=2b, 01=3b, 10=4b, 11=16b-bypass)
  [27:20] sequence_id (up to 256 sequences, but cfg limits to 4-16)
  [19:10] token_id (up to 1024)
  [9:0]   reserved / flags

Page table stored in dedicated SRAM partition (2048 entries x 32 bits = 8KB)
```

### DMA Engine

The DMA engine handles streaming compressed KV data between on-chip SRAM and an off-chip memory interface. For v1, the off-chip interface is exposed as Wishbone master transactions that the Caravel SoC or an external FPGA can bridge to DRAM.

```
DMA Descriptor: 64 bits
  [63:48] source_page_id
  [47:32] dest_addr (off-chip, 16-bit word address)
  [31:16] transfer_length (in 32-bit words)
  [15:0]  flags (compress_on_write, decompress_on_read, interrupt_on_done)

DMA FIFO depth: 8 descriptors
Sustained throughput target: 1 word/cycle at 50MHz = 200 MB/s
```

### Interface Signals

```verilog
module memory_hierarchy_controller (
    input  wire        clk,
    input  wire        rst_n,

    // Wishbone slave (host access)
    input  wire        wbs_cyc_i,
    input  wire        wbs_stb_i,
    input  wire        wbs_we_i,
    input  wire [3:0]  wbs_sel_i,
    input  wire [31:0] wbs_adr_i,
    input  wire [31:0] wbs_dat_i,
    output wire [31:0] wbs_dat_o,
    output wire        wbs_ack_o,

    // Wishbone master (off-chip DMA)
    output wire        wbm_cyc_o,
    output wire        wbm_stb_o,
    output wire        wbm_we_o,
    output wire [3:0]  wbm_sel_o,
    output wire [31:0] wbm_adr_o,
    output wire [31:0] wbm_dat_o,
    input  wire [31:0] wbm_dat_i,
    input  wire        wbm_ack_i,

    // KV Cache Engine interface
    output wire        kv_write_valid,
    input  wire        kv_write_ready,
    output wire [31:0] kv_write_addr,
    output wire [31:0] kv_write_data,
    // ... (read interface similar)

    // Token Importance Unit interface
    input  wire        evict_valid,
    output wire        evict_ready,
    input  wire [9:0]  evict_token_id,
    input  wire [1:0]  evict_action,

    // SRAM bank interfaces (directly to CF_SRAM_16384x32 instances)
    // 8 banks, directly wired
    output wire [7:0]  sram_csb,           // chip select (active low)
    output wire [7:0]  sram_web,           // write enable (active low)
    output wire [13:0] sram_addr [7:0],    // 14-bit address per bank
    output wire [31:0] sram_din  [7:0],    // write data
    input  wire [31:0] sram_dout [7:0],    // read data
    output wire [3:0]  sram_wmask [7:0],   // byte write mask

    // Status
    output wire [10:0] status_occupancy,   // pages in use
    output wire        status_dma_busy,
    output wire [7:0]  status_bank_util    // per-bank utilization
);
```

### Area Estimate

- Page table SRAM: 8KB (shared from existing SRAM)
- DMA engine + descriptor FIFO: ~0.02 mm²
- Arbiter + bank select logic: ~0.01 mm²
- Control state machines: ~0.01 mm²
- **Total estimate: ~0.05 mm²** (plus SRAM macros)

---

## 8. Block 4: Lightweight Attention Compute Unit

### Purpose

A minimal dot-product engine used for two purposes:
1. **Token scoring:** compute partial Q*K dot products to feed the Token Importance Unit
2. **Attention assist:** optionally compute full Q*K attention scores for a tile of tokens, returning results to the host

This block has two implementation options described below: a baseline parallel dot-product unit (must-have) and an optional 1D systolic array upgrade (should-have) that reduces SRAM bandwidth pressure.

### Functional Requirements

| ID | Requirement | Priority |
|---|---|---|
| AC-01 | Compute dot product of two 32-element vectors in <=4 cycles | Must-have |
| AC-02 | Accumulate partial dot products across multiple vector chunks | Must-have |
| AC-03 | Support both operating modes: dequantized 16-bit input OR compressed-domain 4-bit input | Must-have |
| AC-04 | Output: 32-bit accumulated dot product result | Must-have |
| AC-05 | Batch mode: iterate over N stored K vectors, producing N scores (one per token) | Should-have |
| AC-06 | Saturation arithmetic (no overflow wrap) | Must-have |
| AC-07 | Optional ReLU or absolute-value output mode (for importance scoring) | Should-have |
| AC-08 | 1D systolic array mode for data-reuse across token sweep (see below) | Should-have |

### Compute Precision Strategy

The attention dot product is `score = Q * K` where Q arrives at 16-bit from the host and K is stored compressed at 2-4 bit (INT4, not FP4). There are two operating modes:

**Mode A — Dequantized compute (baseline):** The KV Cache Engine dequantizes K back to 16-bit, and the dot product uses 16x16-bit multipliers. Highest accuracy, largest multipliers.

**Mode B — Compressed-domain compute:** Skip dequantization entirely. Multiply 16-bit Q elements directly against 4-bit K elements using 16x4-bit multipliers. The scale factor is applied once to the accumulated result rather than per-element.

```
Dequant mode:   score = Σ Q[i] * (K_q[i] * scale + zp)  = scale * Σ Q[i]*K_q[i] + zp * Σ Q[i]
Compressed mode: score = scale * Σ Q[i] * K_q[i] + zp * Σ Q[i]   (mathematically equivalent)
```

Since the scale factor multiplies the final sum, not each element, compressed-domain compute is mathematically identical to dequant-then-compute for symmetric quantization (zero_point = 0). For asymmetric quantization, the `zp * Σ Q[i]` correction term can be precomputed once per query.

| Mode | Multiplier Size | Area (32-wide) | Accuracy | Use Case |
|---|---|---|---|---|
| A: Dequant first | 16x16 → 32-bit | ~0.04 mm² | Best | Default for important tokens |
| B: Compressed-domain | 16x4 → 20-bit | ~0.01 mm² | Good (<1% relative error at 4-bit) | Fast sweep for scoring |

**Design decision:** Implement both modes, selected via CSR. The multiplier array accepts either 16-bit or 4-bit K inputs. In compressed-domain mode, the upper 12 bits of each K input are zeroed and the smaller multiply is synthesized efficiently by the tools. This costs minimal additional area (a mux per input) while enabling a 4x area reduction in the datapath when accuracy tolerance permits.

**Why INT4, not FP4?** NVIDIA's MXFP4 (1 sign, 2 exponent, 1 mantissa) provides non-uniform spacing with better dynamic range near zero. However, FP4 multipliers require exponent addition, mantissa multiplication, normalization, and special-case handling (subnormals, zeros) — roughly 3-5x the gate count of an INT4 multiply. At 130nm, where every gate is ~10x the cost of a 5nm gate, this overhead is disproportionate. INT4 with a per-group shared scale factor achieves equivalent effective dynamic range with pure integer arithmetic.

### Microarchitecture — Option A: Parallel Dot-Product (Must-Have Baseline)

```
Query Vector (32 x 16-bit)    Key Vector (32 x 4/16-bit, mode-dependent)
        │                              │
        ▼                              ▼
┌─────────────────────────────────────────────┐
│           Element-wise Multiply              │
│           32 parallel multipliers            │
│           (16x16 in Mode A, 16x4 in Mode B) │
└─────────────────────┬───────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────┐
│           Adder Tree (32→1)                  │
│           5-stage pipelined binary reduction  │
└─────────────────────┬───────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────┐
│           Scale + Zero-Point Correction      │
│           (one 32x16 multiply for scale,     │
│            add precomputed zp term)           │
└─────────────────────┬───────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────┐
│           Accumulator                        │
│           Running sum across chunks           │
└─────────────────────┬───────────────────────┘
                      │
                      ▼
              32-bit Score Output
```

For a 128-dimensional KV head, processing 32 elements per cycle means 4 cycles per full dot product. For 1024 stored tokens, a full sweep takes 4096 cycles = ~82 us at 50MHz.

### Microarchitecture — Option B: 1D Systolic Array (Should-Have Upgrade)

If SRAM read bandwidth becomes a bottleneck during integration (because the Memory Hierarchy Controller and the Attention Compute Unit contend for the same SRAM ports), a 1D systolic array trades a modest area increase for a significant reduction in SRAM reads.

```
  Q elements loaded once, held in PE registers:

     ┌──────┐    ┌──────┐    ┌──────┐         ┌──────┐
K ──►│ PE 0  ├───►│ PE 1  ├───►│ PE 2  ├── ··· ►│ PE 7  ├──► partial sum out
     │q[0-3]│    │q[4-7]│    │q[8-11]│         │q[28-31]│
     └──────┘    └──────┘    └──────┘         └──────┘

Each PE: holds 4 Q elements in local registers
         receives 4 K elements from left neighbor (or SRAM for PE 0)
         computes 4 multiply-adds to running accumulator
         passes K elements and accumulated sum to right neighbor
```

**8 PEs, each with 4 multipliers = 32 multipliers total** (same compute as baseline, different organization).

| Metric | Parallel Dot-Product | 1D Systolic (8 PE) |
|---|---|---|
| Multipliers | 32 (all read from SRAM) | 32 (K data flows PE-to-PE) |
| SRAM reads per 1024-token sweep | 4096 Q reads + 4096 K reads | 32 Q reads (once) + 4096 K reads |
| SRAM bandwidth reduction | Baseline | ~2x (Q is reused across all tokens) |
| Pipeline fill latency | 0 (fully parallel) | 7 cycles (data must propagate through 8 PEs) |
| Sustained throughput | 1 dot-product per 4 cycles | 1 dot-product per 4 cycles (after fill) |
| Area | ~0.04-0.06 mm² | ~0.08-0.12 mm² (inter-PE registers + routing) |
| Verification complexity | Low | Medium (wave scheduling, pipeline flush) |

**Recommendation:** Implement the parallel dot-product baseline in Phase 2. If integration testing reveals SRAM port contention, upgrade to the systolic variant — the external interface is identical, only the internal datapath changes. This is a clean drop-in replacement.

### Area Estimate

- **Baseline (parallel, Mode A+B):** ~0.06 mm²
  - 32 x 16-bit multipliers with 4-bit input mode: ~0.04 mm²
  - Adder tree: ~0.01 mm²
  - Scale correction + accumulator + control: ~0.01 mm²
- **With systolic upgrade:** ~0.12 mm²
  - 32 multipliers + 8 PE register sets + inter-PE routing: ~0.08 mm²
  - Adder tree + accumulator: ~0.02 mm²
  - Systolic control FSM: ~0.02 mm²

---

## 9. Top-Level Integration & Interfaces

### Top-Level Block Diagram

```
                         ┌──────────────────────────────────┐
                         │         LASSO Top-Level           │
                         │                                   │
        Wishbone B4      │  ┌───────────┐   ┌───────────┐  │
  ◄─────Slave I/F───────►│  │ CSR Block  │   │ Interrupt  │  │
        (Host)           │  │ (config,   │   │ Controller │  │
                         │  │  status)   │   │            │  │
                         │  └─────┬─────┘   └─────┬─────┘  │
                         │        │               │         │
                         │  ┌─────▼───────────────▼─────┐  │
                         │  │     Internal Crossbar       │  │
                         │  │     (4-master, N-slave)      │  │
                         │  └──┬──────┬──────┬──────┬───┘  │
                         │     │      │      │      │      │
                         │  ┌──▼──┐┌──▼──┐┌──▼──┐┌──▼──┐  │
                         │  │ KV  ││Token││ MHC ││Attn │  │
                         │  │Cache││ Imp ││     ││Comp │  │
                         │  │ Eng ││Unit ││     ││Unit │  │
                         │  └─────┘└─────┘└──┬──┘└─────┘  │
                         │                   │             │
                         │         ┌─────────▼─────────┐   │
                         │         │   SRAM Subsystem   │   │
                         │         │  (4-8x 64KB banks) │   │
                         │         └─────────┬─────────┘   │
                         │                   │             │
                         └───────────────────┼─────────────┘
                                             │
                                    Wishbone B4 Master
                                    (Off-chip DMA)
```

### Address Map (Wishbone Slave)

| Address Range | Block | Description |
|---|---|---|
| 0x0000_0000 - 0x0000_00FF | CSR | Global configuration and status registers |
| 0x0000_0100 - 0x0000_01FF | KV Cache Engine CSR | Quantization config, outlier threshold |
| 0x0000_0200 - 0x0000_02FF | Token Importance CSR | Eviction policy, watermark, sink count |
| 0x0000_0300 - 0x0000_03FF | Memory Hierarchy CSR | DMA descriptors, page table base, bank config |
| 0x0000_0400 - 0x0000_04FF | Attention Compute CSR | Query register load, result readback |
| 0x0001_0000 - 0x0008_FFFF | SRAM Direct Access | Raw read/write to SRAM banks (debug) |
| 0x0010_0000 - 0x0010_1FFF | Page Table | Direct access to page table entries |
| 0x0020_0000 - 0x0020_07FF | Score Table | Token importance scores (debug readback) |

### Global CSR Registers

| Offset | Name | Description |
|---|---|---|
| 0x00 | CTRL | Global enable, soft reset, clock gate control |
| 0x04 | STATUS | Busy flags, error flags, interrupt pending |
| 0x08 | VERSION | Hardware version ID (read-only) |
| 0x0C | CAPABILITY | Feature flags: supported bit-widths, max tokens, bank count |
| 0x10 | IRQ_ENABLE | Interrupt enable mask |
| 0x14 | IRQ_STATUS | Interrupt status (write-1-to-clear) |
| 0x18 | PERF_CYCLE | Cycle counter (for performance measurement) |
| 0x1C | PERF_TOKEN | Token counter (tokens processed) |

### Interrupt Sources

| Bit | Source | Description |
|---|---|---|
| 0 | DMA_DONE | DMA transfer completed |
| 1 | EVICT_DONE | Eviction batch completed |
| 2 | SRAM_FULL | SRAM occupancy exceeded watermark |
| 3 | SCORE_READY | Attention score computation completed |
| 4 | ERROR | Parity error, bus error, or page fault |

### Clock & Reset

- Single clock domain (50-100 MHz target)
- Synchronous active-low reset
- Optional clock gating per block (CSR-controlled) for power savings during idle

---

## 10. SRAM Subsystem & Existing IP

### CF_SRAM_16384x32 (from LonghornSilicon GitHub)

The existing [CF_SRAM_16384x32](https://github.com/LonghornSilicon/SRAM_16384x32) macro is the foundation of LASSO's on-chip memory. Key characteristics:

| Parameter | Value |
|---|---|
| Capacity | 16384 words x 32 bits = 64 KB |
| Address width | 14 bits |
| Data width | 32 bits |
| Byte enable | wbs_sel_i[3:0] |
| Interface | Wishbone B4 slave |
| Internal structure | 16x CF_SRAM_1024x32 in 2-col x 8-row layout |
| Scan chain | Yes (included for testability) |
| IP source | CF (Caravel-compatible) via IPM |

### SRAM Bank Allocation Plan

| Bank ID | Macro | Purpose | Capacity |
|---|---|---|---|
| 0-3 | 4x CF_SRAM_16384x32 | KV Cache Primary Store | 256 KB |
| 4-5 | 2x CF_SRAM_16384x32 | KV Cache Secondary / Overflow | 128 KB |
| 6 | 1x CF_SRAM_16384x32 | Page Table + Score Table + Metadata | 64 KB |
| 7 | 1x CF_SRAM_16384x32 | Working Buffer (DMA staging, quant scratch) | 64 KB |

**Total: 8 macros, 512 KB**

### What 512KB Buys You

At 2-bit quantization with 128-dim KV heads:

| Model Config | Bytes per Token (K+V) | Max Tokens in 256KB Primary | Max Tokens in 384KB (Primary+Secondary) |
|---|---|---|---|
| 4 KV heads, 128 dim, 2-bit | 128 B | ~2048 | ~3072 |
| 4 KV heads, 128 dim, 4-bit | 256 B | ~1024 | ~1536 |
| 8 KV heads, 128 dim, 2-bit | 256 B | ~1024 | ~1536 |
| 8 KV heads, 128 dim, 4-bit | 512 B | ~512 | ~768 |

For a GQA model with 4 KV heads at 2-bit, 2048 tokens on-chip is a meaningful working set. Overflow beyond this is streamed off-chip via the DMA engine.

---

## 11. Quantization Strategy

### v1 Strategy: Linear Fixed-Point Quantization

Based on the research analysis in `arch-ref.md` and the survey of RotateKV, GEAR, and TurboQuant, the v1 quantization strategy is:

**Per-group symmetric linear quantization** as the baseline, with optional asymmetric mode.

```
Quantize:   q = clamp(round(x / scale), -2^(b-1), 2^(b-1) - 1)
Dequantize: x_hat = q * scale

where scale = max(abs(group)) / (2^(b-1) - 1)
group = contiguous block of 32/64/128 elements
```

### Precision Modes

| Mode | Bits | Format | Scale Overhead | Effective Compression vs 16-bit |
|---|---|---|---|---|
| Q2 | 2-bit | INT2 (signed) | 16-bit scale per group of 32 | ~7x |
| Q3 | 3-bit | INT3 (signed) | 16-bit scale per group of 32 | ~4.5x |
| Q4 | 4-bit | INT4 (signed) | 16-bit scale per group of 32 | ~3.5x |
| Bypass | 16-bit | INT16 (signed) | None | 1x (no compression) |

All modes use integer (INTn) format, not floating-point (FPn). NVIDIA's MXFP4 format (1 sign, 2 exponent, 1 mantissa bits with shared block exponent) provides non-uniform spacing better suited to Gaussian-distributed data, but FP4 multipliers require exponent addition, mantissa handling, normalization, and subnormal/zero special-casing — roughly 3-5x the gate count of equivalent INT4 multipliers. At 130nm, where gate area is ~10x that of modern processes, this overhead is disproportionate to the marginal quality benefit. INT4 with a per-group shared 16-bit scale factor achieves equivalent effective dynamic range using pure integer arithmetic.

### Why Not PolarQuant for v1

PolarQuant (from TurboQuant) achieves ~70% compression with 3-bit angles and preserved magnitudes. However:

1. **Reconstruction requires trigonometric operations.** Each level of the tree requires sin/cos evaluation. For a 512-dim vector (9-level tree), that's 511 trig operations per dequant. CORDIC units at 130nm consume ~0.01 mm² each; 32 parallel CORDICs for throughput would be ~0.3 mm² — 3x the entire attention compute unit.
2. **Hadamard preconditioning is feasible** (it's just adds/subtracts), but the full polar pipeline adds latency.
3. **Linear quantization with outlier handling** (RotateKV-style) achieves comparable quality at 2-bit with far simpler hardware.

**PolarQuant remains a v2 target** if area permits or if a second tapeout is planned.

### v2 Aspirations (Post-Tapeout)

- PolarQuant with CORDIC-based sin/cos reconstruction
- Channel rotation (RotateKV-style) pre-quantization
- Sparse dictionary coding (Lexico-inspired) with on-chip codebook
- Mixed-precision per-head quantization driven by Token Importance Unit

---

## 12. Verification Plan

### Verification Strategy

Three-level verification: unit-level, block-level, and system-level, all in simulation.

| Level | Tool | Description |
|---|---|---|
| Unit | Verilator + cocotb | Individual module functional tests |
| Block | Verilator + cocotb | Per-block integration with stimulus from reference models |
| System | Verilator + cocotb | Full chip with Wishbone BFM, DMA traffic, multi-sequence workloads |
| Formal | SymbiYosys (optional) | Bounded model checking on critical FSMs (page table, DMA) |
| Gate-level | OpenSTA + Verilator | Post-synthesis timing and functional verification |

### Reference Model

A Python golden model will be developed alongside the RTL:

```
golden_model/
├── kv_quantizer.py      # Bit-exact quantization/dequantization
├── token_scorer.py      # Token importance scoring algorithm
├── page_manager.py      # Page allocation, eviction logic
├── attention_compute.py # Dot product and accumulation
└── lasso_system.py      # Full system model with Wishbone transactions
```

All RTL testbenches compare output against this golden model, bit-for-bit where applicable.

### Test Plan Summary

| Test Category | Count (Est.) | Description |
|---|---|---|
| KV Engine: Quantize sweep | ~20 | All bit-widths, group sizes, edge cases (all zeros, all max, mixed) |
| KV Engine: Dequant accuracy | ~20 | Verify reconstruction error within expected bounds |
| KV Engine: Outlier handling | ~10 | Threshold sweep, mixed outlier patterns |
| KV Engine: Bit packing | ~10 | Pack/unpack round-trip for all configurations |
| Token Importance: Score accumulation | ~15 | Sequential scoring, overflow, reset |
| Token Importance: Eviction | ~15 | Watermark trigger, bottom-K selection, sink protection |
| Memory Hierarchy: Page allocation | ~20 | Alloc/free sequences, fragmentation, full-buffer handling |
| Memory Hierarchy: DMA | ~15 | Read/write, back-to-back, error injection |
| Memory Hierarchy: Mixed precision | ~10 | Same token at different precisions, precision change |
| Attention Compute: Dot product | ~15 | Known vectors, accumulation, saturation |
| System: End-to-end encode | ~10 | Token arrival → quantize → score → store |
| System: End-to-end decode | ~10 | Query → fetch → dequant → dot product → return |
| System: Multi-sequence | ~5 | 4 concurrent sequences, interleaved |
| System: Eviction under pressure | ~5 | Fill buffer, verify correct eviction and DMA |
| System: Wishbone protocol | ~10 | Back-pressure, stalls, byte enables, errors |
| **Total** | **~180** | |

### Continuous Integration

- All tests run on every commit via GitHub Actions
- Verilator lint checks (warnings-as-errors)
- cocotb tests with randomized seeds
- Coverage reports (line + toggle) tracked per block

---

## 13. Physical Design Plan

### Toolchain

| Stage | Tool |
|---|---|
| Synthesis | Yosys (with SKY130 liberty files) |
| Floorplanning | OpenROAD (manual macro placement guidance) |
| Placement | DREAMPlace (via OpenROAD) |
| CTS | OpenROAD TritonCTS |
| Routing | TritonRoute |
| Signoff DRC/LVS | Magic + Netgen |
| STA | OpenSTA |
| GDSII | Magic (final export) |
| Flow Manager | OpenLane 2 |

### Floorplan

```
┌──────────────────────────────────────────────────┐
│                   I/O Ring + Pads                  │
│  ┌──────────────────────────────────────────────┐ │
│  │                                              │ │
│  │   ┌────────┐ ┌────────┐ ┌────────┐ ┌──────┐│ │
│  │   │SRAM 0  │ │SRAM 1  │ │SRAM 2  │ │SRAM 3││ │
│  │   │(64KB)  │ │(64KB)  │ │(64KB)  │ │(64KB)││ │
│  │   └────────┘ └────────┘ └────────┘ └──────┘│ │
│  │                                              │ │
│  │   ┌────────┐ ┌────────┐ ┌────────┐ ┌──────┐│ │
│  │   │SRAM 4  │ │SRAM 5  │ │SRAM 6  │ │SRAM 7││ │
│  │   │(64KB)  │ │(64KB)  │ │(64KB)  │ │(64KB)││ │
│  │   └────────┘ └────────┘ └────────┘ └──────┘│ │
│  │                                              │ │
│  │   ┌────────────┐ ┌──────────────────────────┐│ │
│  │   │ KV Cache    │ │ Memory Hierarchy         ││ │
│  │   │ Engine      │ │ Controller               ││ │
│  │   │             │ │ (incl. DMA, page table)  ││ │
│  │   └────────────┘ └──────────────────────────┘│ │
│  │                                              │ │
│  │   ┌────────────┐ ┌──────────────────────────┐│ │
│  │   │ Token       │ │ Attention Compute        ││ │
│  │   │ Importance  │ │ + CSR Block + IRQ Ctrl   ││ │
│  │   │ Unit        │ │                          ││ │
│  │   └────────────┘ └──────────────────────────┘│ │
│  │                                              │ │
│  └──────────────────────────────────────────────┘ │
│                   I/O Ring + Pads                  │
└──────────────────────────────────────────────────┘
```

### Area Budget

| Block | Estimated Area (Baseline) | With Systolic Upgrade | % of 10mm² (Baseline) |
|---|---|---|---|
| SRAM Subsystem (8x 64KB) | 6.5 mm² | 6.5 mm² | 65% |
| KV Cache Engine | 0.07 mm² | 0.07 mm² | 0.7% |
| Token Importance Unit | 0.02 mm² | 0.02 mm² | 0.2% |
| Memory Hierarchy Controller | 0.05 mm² | 0.05 mm² | 0.5% |
| Attention Compute Unit | 0.06 mm² | 0.12 mm² | 0.6-1.2% |
| Top-level (crossbar, CSR, IRQ, clock tree) | 0.1 mm² | 0.1 mm² | 1% |
| I/O pads + pad ring | 1.5 mm² | 1.5 mm² | 15% |
| Routing overhead + fill | 1.5 mm² | 1.5 mm² | 15% |
| **Total** | **~9.8 mm²** | **~9.86 mm²** | **~98%** |

SRAM dominates. This is expected and correct: LASSO is a memory-centric design. The logic blocks are small because they are purpose-built datapaths, not general-purpose compute.

### Timing Targets

| Path | Target | Margin Strategy |
|---|---|---|
| SRAM read → KV dequant → dot product | 20 ns (50 MHz) | Pipeline with 2 register stages |
| Wishbone slave → CSR read | 20 ns | Single-cycle response |
| Quantize pipeline | 4 cycles @ 50 MHz | Fully pipelined, 1 result/cycle throughput |
| DMA burst | 1 word/cycle sustained | Back-pressure via ready/valid |

---

## 14. Risk Register

| ID | Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| R-01 | SRAM macros don't meet timing at 50MHz | Medium | High | Run OpenSTA early; be prepared to drop to 25MHz |
| R-02 | 8 SRAM macros don't fit in chipIgnite die area | Medium | High | Reduce to 4 macros (256KB) as fallback; still demonstrates full datapath |
| R-03 | OpenLane routing congestion near SRAM macro edges | Medium | Medium | Manual floorplan guidance; leave routing channels between macros |
| R-04 | Efabless shuttle schedule slips or becomes unavailable | Low | Critical | Track ChipFoundry schedule; maintain Tiny Tapeout as backup (smaller area) |
| R-05 | Team attrition (students graduate/leave) | Medium | High | Document everything; cross-train on RTL and PD; modular design enables partial delivery |
| R-06 | Quantization accuracy insufficient for demo | Low | Medium | Bypass mode allows 16-bit pass-through; can always demo the memory management independently |
| R-07 | Verification coverage insufficient | Medium | Medium | Prioritize golden model; randomized testing catches most bugs |
| R-08 | Post-silicon SRAM yield issues | Medium | High | Include scan chain (already in SRAM IP); plan bring-up with SRAM self-test first |
| R-09 | Scope creep (adding MLP, full attention, speculative decode) | High | High | This PRD is the scope. Anything not in this document is v2. |
| R-10 | Clock tree distribution across 8 SRAM macros | Medium | Medium | Use OpenROAD CTS with buffer insertion; keep single clock domain |

---

## 15. Phased Delivery & Scope Cuts

### Phase Definition

Each phase produces a demonstrably working artifact. No phase depends on completing a "nice-to-have" from a previous phase.

#### Phase 0: Infrastructure (Now → Summer 2026)

**Deliverable:** Development environment, golden model, SRAM macro integration validated.

| Task | Owner | Status |
|---|---|---|
| Set up Verilator + cocotb CI pipeline | Build track | Pending |
| Validate CF_SRAM_16384x32 in OpenLane flow (standalone synthesis + PnR) | Build track | Pending |
| Develop Python golden model for quantization and page management | Research track | Pending |
| Finalize quantization bit-widths and group sizes from simulation studies | Research track | Pending |
| Produce test vectors from real model KV cache dumps (e.g. Qwen-0.5B, Llama-3.2-1B) | Research track | Pending |

#### Phase 1: Core Datapath (Fall 2026)

**Deliverable:** KV Cache Engine + Memory Hierarchy Controller passing all unit and block tests.

| Task | Priority |
|---|---|
| KV Cache Engine RTL (quantize + dequant + pack/unpack) | Must-have |
| Memory Hierarchy Controller RTL (page table, SRAM bank arbiter) | Must-have |
| Wishbone slave interface and CSR block | Must-have |
| Block-level verification against golden model | Must-have |
| Outlier detection and handling | Should-have |

**Scope cut if behind schedule:** Drop outlier detection. Ship uniform quantization only.

#### Phase 2: Intelligence (Spring 2027)

**Deliverable:** Token Importance Unit + Attention Compute Unit integrated and verified end-to-end.

| Task | Priority |
|---|---|
| Token Importance Unit RTL (score accumulator, comparator tree, eviction FSM) | Must-have |
| Attention Compute Unit RTL (dot product engine) | Must-have |
| DMA engine RTL | Must-have |
| System-level integration (all 4 blocks + SRAM + top-level) | Must-have |
| Mixed-precision storage per token importance | Should-have |
| Multi-sequence support (4 sequences) | Should-have |
| Double-buffering in SRAM | Should-have |

**Scope cut if behind schedule:** Drop multi-sequence support (single sequence only). Drop mixed-precision (use uniform precision for all tokens). Drop double-buffering (single-buffer with stalls).

#### Phase 3: Physical Design & Tapeout (Summer-Fall 2027)

**Deliverable:** GDSII submitted to Efabless.

| Task | Priority |
|---|---|
| Synthesis with Yosys + SKY130 | Must-have |
| Floorplanning (SRAM macro placement) | Must-have |
| Place and route with OpenROAD | Must-have |
| STA signoff at target frequency | Must-have |
| DRC/LVS clean | Must-have |
| Gate-level simulation | Must-have |
| Power analysis | Should-have |
| IR drop analysis | Should-have |

**Scope cut if behind schedule:** Reduce SRAM from 8 to 4 macros. Reduce clock target from 50MHz to 25MHz.

#### Phase 4: Silicon & Demo (Spring 2028)

**Deliverable:** Working chip, demo, writeup.

| Task | Priority |
|---|---|
| Bring-up plan: SRAM self-test, scan chain verification | Must-have |
| Functional test: write KV vectors, read back compressed, verify accuracy | Must-have |
| Performance measurement: throughput, latency, power | Must-have |
| Demo: compress real model KV cache, show accuracy preservation | Must-have |
| Technical report / workshop paper | Must-have |

### What Is Explicitly OUT of Scope for v1

| Feature | Reason | Target |
|---|---|---|
| Speculative decoding | Too complex; requires dual model state and rollback | v2 |
| Full attention (softmax + V weighting) | Area prohibitive at 130nm; host can do softmax | v2 |
| MLP / FFN compute | Not part of KV cache management | v2 / never |
| PolarQuant (trigonometric reconstruction) | CORDIC area cost too high | v2 |
| Sparse dictionary coding (Lexico-style) | Requires OMP solver, too complex for first silicon | v2 |
| eDRAM macros | Not available in standard SKY130 PDK | v2 (different process) |
| Multi-chip / chiplet interface | Way out of scope | v3 |
| MoE routing hardware | Different problem entirely | Separate project |
| Analog in-memory compute | Incompatible with SKY130 digital flow | Out of scope |

---

## 16. Timeline

```
2026
────────────────────────────────────────────────────────────────
Apr-May     ▓▓▓▓▓  PRD finalization, team recruitment
Jun-Aug     ▓▓▓▓▓▓▓▓▓  Phase 0: Infra + golden model + SRAM validation
Sep-Dec     ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓  Phase 1: Core datapath RTL + verification
            └─ Architecture Decision Document due end of Fall 2026

2027
────────────────────────────────────────────────────────────────
Jan-May     ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓  Phase 2: Intelligence blocks + system integration
Jun-Jul     ▓▓▓▓▓▓▓▓  Phase 3a: Synthesis + floorplan + initial PnR
Aug-Oct     ▓▓▓▓▓▓▓▓▓▓▓  Phase 3b: PnR iteration, timing closure, DRC/LVS
Nov-Dec     ▓▓▓▓▓▓▓  Phase 3c: Gate-level sim, signoff, GDSII generation
            └─ Efabless shuttle submission (target: Nov 2027)

2028
────────────────────────────────────────────────────────────────
Jan-Feb     ░░░░░░░░  Fab turnaround (out of our hands)
Mar-May     ▓▓▓▓▓▓▓▓▓▓▓  Phase 4: Bring-up, characterization, demo, paper
            └─ Target: demo at UT ECE spring showcase
```

### Key Milestones

| Date | Milestone | Gate Criteria |
|---|---|---|
| Aug 2026 | Golden model complete | All quantization modes produce correct output on real KV data |
| Sep 2026 | SRAM macro validated in OpenLane | Standalone synthesis + PnR + DRC clean |
| Dec 2026 | Phase 1 RTL freeze | KV Engine + MHC passing all block-level tests |
| May 2027 | Phase 2 RTL freeze | Full system passing end-to-end tests |
| Jul 2027 | First synthesis results | Area and timing estimates validated |
| Oct 2027 | Timing closure achieved | All paths meet 50MHz (or fallback frequency) |
| Nov 2027 | GDSII submitted | DRC/LVS clean, gate-level sim passing |
| Apr 2028 | Silicon demo | Functional chip demonstrated |

---

## 17. Team Structure & Ownership

Following the founding document's principle: every member has an explicit owner role. No role, no membership.

| Role | Count | Responsibilities |
|---|---|---|
| Architecture Lead | 1 | Owns this PRD. Makes architecture decisions. Maintains golden model. Bridges research and build. |
| RTL Lead | 1 | Owns Verilog codebase. Reviews all RTL PRs. Owns KV Cache Engine and Attention Compute blocks. |
| RTL Engineer | 1-2 | Implements Token Importance Unit and Memory Hierarchy Controller. Writes testbenches. |
| Verification Lead | 1 | Owns cocotb test infrastructure, CI pipeline, coverage tracking, golden model integration. |
| Physical Design Lead | 1 | Owns OpenLane flow, floorplan, timing closure, GDSII signoff. Works with Prof. Pan. |
| Research Analyst | 0-1 | Produces quantization studies, benchmark data, test vectors from real models. Feeds architecture decisions. |

### Reporting Structure

```
Architecture Lead
    ├── RTL Lead
    │     └── RTL Engineer(s)
    ├── Verification Lead
    ├── Physical Design Lead
    └── Research Analyst
```

The Architecture Lead is the single decision-maker for the `#arch-decisions` channel. When research and build disagree, architecture decides.

---

## 18. Success Criteria

### Minimum Viable Tapeout (Must achieve ALL)

1. GDSII submitted to Efabless shuttle by Nov 2027
2. Design passes DRC and LVS signoff
3. Gate-level simulation demonstrates correct KV quantization round-trip (quantize → store → fetch → dequantize → verify within expected error bounds)
4. At least 2-bit and 4-bit quantization modes functional
5. Wishbone host interface functional (host can write raw KV, read compressed KV)
6. Scan chain operational for post-silicon debug

### Target (Aim for ALL, acceptable to miss 1-2)

7. Token importance scoring and eviction functional end-to-end
8. DMA engine functional for off-chip streaming
9. Dot-product attention scoring functional
10. 50 MHz clock achieved
11. 512 KB on-chip SRAM (8 macros)
12. Multi-sequence support (at least 2 concurrent sequences)

### Stretch (Bonus)

13. Silicon returns functional (SRAM self-test passes)
14. Live demo: compress KV cache from a real 1B-parameter model, show accuracy preservation
15. Workshop paper accepted (DAC/ICCAD student competition, ISSCC demo session, or similar)
16. Measured power numbers publishable

### What "Success" Looks Like to Each Audience

| Audience | Success = |
|---|---|
| Team members | "I taped out a chip in college that addresses a real AI infrastructure problem" |
| Faculty | "They demonstrated system-level architecture thinking and executed a complete design flow" |
| Industry sponsors | "They understand the memory wall and built hardware that addresses it" |
| Open-source community | "There's now an open-source KV cache compression engine I can fork and extend" |

---

## 19. Reference Architecture & Prior Art

### Primary References

| Paper/Project | Relevance | Key Takeaway for LASSO |
|---|---|---|
| **Titanus** (GLSVLSI'25) | Highest | Cascade pruning + quantization co-design; 159.9x energy efficiency; SRAM vs eDRAM analysis; closest to our architecture |
| **BalanceKV** (NeurIPS'25) | High | Theoretical guarantees for token sampling; informs our eviction policy design |
| **GEAR** (ArXiv'24) | High | Practical 4-bit quant + low-rank correction; shows that simple quantization gets you most of the way |
| **RotateKV** (AAAI'25) | High | 2-bit quantization with channel rotations; validates aggressive quantization is viable |
| **MiKV / No Token Left Behind** (ArXiv'24) | High | Mixed-precision KV cache; never fully evict; quantize instead; core insight for our Token Importance Unit |
| **TurboQuant** (Google, Mar 2026) | Medium | PolarQuant 3-bit scheme; promising but hardware-expensive; v2 target |
| **HADES** (ICCEA'25) | Low (v2) | Speculative decode in hardware; future direction, not v1 |
| **Taalas HC1** (Feb 2026) | Context | Shows industry appetite for fixed-function LLM silicon; 17K tok/s on hardwired Llama 3.1 |
| **FlashAttention-4** (ArXiv'26) | Context | Attention is memory-bound even on Blackwell; validates our memory-first approach |
| **SHIELD** (ArXiv'26) | Medium | eDRAM refresh optimization; relevant if process supports eDRAM in future revision |
| **T1C** (Open source) | Medium | Open-source LLM accelerator targeting SKY130; potential for shared IP and learnings |

### Open-Source IP Dependencies

| IP | Source | Use |
|---|---|---|
| CF_SRAM_1024x32 | Caravel/IPM ecosystem | Base SRAM macro |
| CF_SRAM_16384x32 | [LonghornSilicon/SRAM_16384x32](https://github.com/LonghornSilicon/SRAM_16384x32) | 64KB SRAM bank |
| Caravel harness | Efabless | Chip-level I/O and management SoC |
| OpenLane 2 | Efabless/OpenROAD | RTL-to-GDSII flow |
| cocotb | cocotb.org | Verification framework |
| Verilator | veripool.org | RTL simulation |

---

## 20. Glossary

| Term | Definition |
|---|---|
| **KV Cache** | The Key-Value cache stored during LLM inference to avoid recomputing attention for past tokens |
| **Quantization** | Reducing numerical precision (e.g., 16-bit to 4-bit) to save memory and bandwidth |
| **Dequantization** | Reconstructing approximate full-precision values from quantized representation |
| **Token Importance** | A score reflecting how much a token contributes to attention; used to decide retention vs eviction |
| **Eviction** | Removing or compressing a token's KV entry from the on-chip cache to free space |
| **Page Table** | A hardware data structure mapping logical token/sequence IDs to physical SRAM locations |
| **DMA** | Direct Memory Access; hardware engine that moves data without CPU intervention |
| **Wishbone B4** | An open-source on-chip bus protocol used by Caravel and many open-source SoC designs |
| **SKY130** | SkyWater 130nm open-source PDK (Process Design Kit) |
| **chipIgnite** | Efabless program providing affordable shuttle access for chip fabrication |
| **OpenLane** | Open-source RTL-to-GDSII flow built on OpenROAD, Yosys, and other tools |
| **GQA** | Grouped Query Attention; model architecture where multiple query heads share KV heads |
| **MoE** | Mixture of Experts; model architecture where only a subset of parameters activate per token |
| **PolarQuant** | Compression scheme encoding vectors as a tree of angles and a final magnitude |
| **CORDIC** | Coordinate Rotation Digital Computer; iterative algorithm for computing trig functions in hardware |
| **SRAM** | Static Random-Access Memory; fast on-chip memory |
| **eDRAM** | Embedded DRAM; denser than SRAM but requires refresh circuitry |
| **GDSII** | Graphic Database System II; the standard file format for IC layout data sent to fabrication |
| **CPQ** | Cascade Pruning-Quantization; Titanus's approach to compressing KV cache on-the-fly |

---

*This document is the scope. Anything not in this document is v2. -- Longhorn Silicon Architecture Team*
