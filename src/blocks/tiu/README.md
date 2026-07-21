# TIU — Token Importance Unit (NEW 2026-05-14)

**Spec source:** `../../../arch.yml` block `token_importance_unit` + `definitive_features_and_blocks.hardware_blocks` entry `TIU`.
**Inspiration:** arXiv 2604.04722 "Adaptive KV-Cache Quantization for Lightweight On-Device LLMs".
**Naming credit:** Chaithu Talasila's attention-compute-unit framework (LonghornSilicon/attention-compute-unit); see `../../../docs/reconciliation_chaithu.md`.

## What this block is

- **Per-block attention-entropy accumulator.** 16-bit importance register per 16-token block; 128 blocks tracked (matches MSC block table); 256 B total SRAM (= 128 blocks × 16-bit register).
- **Updated by VecU during softmax.** Each attention pass: VecU broadcasts cumulative softmax weight per block to TIU; TIU accumulator adds.
- **Consumed by two downstream paths:**
  - MSC eviction policy: when scratchpad fills, evict block with lowest cumulative importance (H2O-style heavy-hitter retention)
  - KVE per-block precision: high-importance blocks stay at the higher ChannelQuant tier (CQ-4+ or CQ-8); low-importance blocks demote to CQ-4 at the cost of quality
- 0.03 mm²; 0.01 W; ~15 verification tests. *(Area/power are 16nm ESTIMATES — arch.yml `token_importance_unit`: 256 B SRAM + comparator + accumulator + threshold reg; analytical, not silicon.)*

## Four CSR-selectable modes

| Mode | Behavior |
|---|---|
| `tiu_off` | No importance tracking. MSC eviction = pure FIFO. KVE = uniform ChannelQuant tier. |
| `tiu_h2o` | Heavy-hitter retention. MSC evicts lowest-importance block. KVE stays at a uniform ChannelQuant tier. |
| `tiu_streaming_llm` | Recent + sink tokens retained. MSC eviction = LRU except for first-N "attention sinks." |
| `tiu_adaptive_precision` | Full adaptive. MSC eviction = importance-driven AND KVE per-block precision = importance-driven. |

## Why this block earns its 0.03 mm²

- Real H2O / TOVA / Scissorhands-style adaptive KV retention claimed **on-silicon**. No closed-source NPU does this today (Apple, Qualcomm, Google all use uniform-precision KV in their NPUs).
- Compounds with the KVE ChannelQuant codec for additional effective compression on long contexts without quality loss. *(The compounding factor — legacy drafts said 1.3-1.7× — is TBD, pending re-derivation for ChannelQuant / Qwen2-1.5B.)*
- Honors Chaithu's TIU framework as a real on-die block; the design here departs from his draft (which was unspecified) and is grounded in arXiv 2604.04722.

## Files (to be written in Phase E)

- `tiu.h`, `tiu.cpp` — top-level Stratus entity
- `importance_sram.h` — 256 B SRAM macro (compiler-generated 1-port HD)
- `accumulator.h` — 16-bit saturating accumulator per block
- `csr.h` — mode + threshold register file
- `tb/` — testbench validating bit-exact against Python golden (`../../golden/tiu.py`; peer of `stratus/`)
- `stratus/project.tcl` — Stratus HLS project (canonical syntax in [`../../../docs/tools-overview.md`](../../../docs/tools-overview.md))

## Open design questions

1. **Per-block vs per-token granularity.** Current spec: per-block (16 tokens) for silicon economy (16× metadata compression vs per-token). Per-token would be 4 KB SRAM (256 B × 16) vs current 256 B; +0.05 mm² area. Likely not worth it given block-level granularity tracks the same heavy-hitter pattern.
2. **Importance update arithmetic.** Add directly (sum of softmax weights per block) vs decay (exponential moving average to favor recent). Current spec: pure sum; decay can be added as a per-cycle multiplier (cheap) if quality eval shows benefit.
3. **Threshold register width.** 16-bit comparison threshold is plenty; 8-bit would also work. Current spec: 16-bit (matches accumulator).
4. **Interaction with sparse-blocked attention** (Phase B add-on 2): when a block is masked out by sparse-blocked, should its importance still update? Likely yes — masked blocks still get their share of attention weight (zero) and decay naturally.
