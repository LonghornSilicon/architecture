# Lambda — Frontier Literature Audit (2026-05)

**Status:** living document. Grows as each Tier-1 paper is read carefully. Final form feeds Phase D consolidation into `arch.yml` and the visual representation.

**Purpose:** comprehensive ground-truth audit of every attention/FFN/KV mechanism we considered for Lambda. For each: paper citation, claim, hardware implication, decision (keep/add/defer/reject), and notes for the visual representation we'll build later.

---

## Decision summary (table form)

| Mechanism | Lambda status | Decision | Source |
|---|---|---|---|
| Multi-head attention (MHA) | ✓ supported | keep | Vaswani 2017 |
| Grouped-query attention (GQA) | ✓ supported (primary) | keep | arXiv 2305.13245 |
| Multi-query attention (MQA) | ✓ supported | keep | Shazeer 2019 |
| PagedAttention (vLLM) | ✓ MSC 128-entry block table | keep | arXiv 2309.06180 |
| FlashAttention-1/2 | ✓ VecU microcode subset | keep | arXiv 2205.14135 / 2307.08691 |
| FlashAttention-3 | ✓ VecU microcode primary | keep | arXiv 2407.08608 |
| FlashInfer kernels | reference taxonomy only | absorb taxonomy | arXiv 2501.01005 |
| Multi-head Latent Attention (MLA) | ❌ not supported | defer to v1.0 | arXiv 2405.04434 |
| Sliding-window attention | ✓ via paged indexing | keep | Mistral 7B technical report |
| Sparse-blocked attention | ❌ → **ADD as add-on 2** | **add (Phase D)** | arXiv 2004.05150 |
| Speculative decoding (Medusa/EAGLE) | architecturally compat. | make explicit | arXiv 2401.10774 |
| Multi-token prediction | architecturally compat. | make explicit | arXiv 2412.19437 (DSV3) |
| Continuous batching | ❌ explicitly NOT supported | reject (single-session chip) | vLLM |
| Mixture of Experts (MoE) | ❌ explicitly NOT supported | reject | Switch / Mixtral |
| Mamba / SSM | ❌ out of scope | reject | arXiv 2312.00752 |
| TurboQuant 3.5b → 4.0 bpe at v2's 16-pt | ✓ KCE-mini primary | keep | arXiv 2504.19874 |
| KVQuant per-channel | ❌ not supported | defer | arXiv 2401.18079 |
| Adaptive precision KV (TIU) | ✓ NEW per Phase 0.3 | **add (add-on 1)** | arXiv 2604.04722 |

Two add-ons confirmed (per user direction): **TIU** (Phase 0.3) and **sparse-blocked attention CSR mode in MSC** (this audit).

---

## Per-mechanism deep dives

Each section below is grown during Phase B reading. Empty sections are stubs to be filled in.

### 1. PagedAttention (vLLM)

**Paper:** Kwon et al., "Efficient Memory Management for Large Language Model Serving with PagedAttention", arXiv 2309.06180, 2023.

**What it claims:** Treat the KV cache like an OS virtual-memory page table. Divide the cache into fixed-size blocks (typically 16 tokens). A per-sequence "block table" maps logical token positions to physical KV blocks. Enables zero-fragmentation memory utilization, prefix sharing, copy-on-write for beam search, and dynamic eviction.

**Lambda status:** ✓ implemented in MSC as a 128-entry block table with 16 tokens/block. We deliberately exclude prefix sharing (single-session chip) and continuous batching.

**Hardware implication for Lambda:** MSC's block-table indexing is the silicon analog of vLLM's block_table. Cost is ~0.05 mm² of CAM-style lookup logic inside MSC's 0.18 mm² total.

**Decision:** Keep as primary KV layout. *Confirmed.*

**Notes for visual rep:** "MSC contains the 128-entry block table; each entry maps (session, layer, block) → physical SRAM address; eviction policy CSR drives which block to retire."

---

### 2. FlashAttention-3

**Paper:** Shah et al., "FlashAttention-3: Fast and Accurate Attention with Asynchrony and Low-Precision", arXiv 2407.08608, 2024.

**What it claims:** Online softmax tiling (FA-2 algorithm) + warpgroup async + low-precision (FP8). Eliminates intermediate materialization of the score matrix; per-row running (m_i, l_i, O_i) state. **Algorithm**: process scores in tiles, maintain running max and running sum-of-exps, rescale accumulators when max updates.

**Lambda status:** ✓ algorithm implemented as VecU microcode (8 lanes × per-row running state). 8 lanes process 8 rows in parallel; tile size 32-64.

**Hardware implication for Lambda:** VecU 1K-microcode RAM holds the FA-3 program. ~32 µops per tile, ~100 tiles per attention for a 3000-token context → ~3200 µops per softmax. The exp() and the rescale are the hot transcendentals; 64-entry LUTs handle them.

**Decision:** Keep. *Confirmed.*

**Open question:** FA-3's "asynchrony" is a GPU warpgroup primitive (overlap matmul with softmax in different warpgroups). Lambda's analog is parallel dispatch from LSU: MatE runs Q·K^T while VecU updates softmax state on the previous tile. Schedule it in LSU.

**Notes for visual rep:** "VecU 8 lanes; per-row (m_i, l_i, O_i) registers; exp LUT 64 entries with linear interp; rescale via mul-by-exp(m_old - m_new); tile of 32 attention scores per microcode iteration."

---

### 3. Multi-head Latent Attention (MLA)

**Paper:** DeepSeek-AI, "DeepSeek-V2: A Strong, Economical, and Efficient Mixture-of-Experts Language Model", arXiv 2405.04434, 2024.

**What it claims:** Compress Q/K/V into a low-rank latent space *before* the attention head split. Reduces per-layer KV by ~10× vs MHA at comparable quality. Different KV layout — instead of (kv_heads × head_dim) per token, store a single (latent_dim) vector per token.

**Lambda status:** ❌ not supported. MSC and KCE-mini assume the GQA/MHA layout (kv_heads × head_dim).

**What would it cost to add:** MSC block-table indexer change; KCE-mini compresses latent vector instead of per-head K/V; MatE Q·K^T becomes Q × (latent → K decompress) which is an additional matmul step. ~+0.05 mm² across blocks; new CSR mode; ~30 verification tests.

**Decision:** **Defer.** Too much arch surface change for the v0.4 spec. Worth revisiting for a v1.0 future Lambda revision IF DeepSeek-style MLA becomes the dominant 3-5B architecture (currently it's a 250B+ MoE technique).

**Notes for visual rep:** "MLA = latent-space KV; Lambda's MSC assumes per-head KV; documented gap, not closed in v0.4."

---

### 4. Adaptive precision KV — the TIU paper

**Paper:** arXiv 2604.04722, "Adaptive KV-Cache Quantization for Lightweight On-Device LLMs", 2026.

**What it claims:** Entropy-based per-token (or per-block) bit-width allocation. High-importance tokens (high attention-weight magnitude) retain higher precision; low-importance ones drop to 2-3 bits with negligible quality loss. Compounds with rotation-codebook quantization (TurboQuant).

**Lambda status:** ✓ NEW — TIU block added in Phase 0.3. Block design grounded in this paper.

**Hardware implication for Lambda:** 256 B importance SRAM (128 blocks × 2 B); update path is VecU softmax → TIU accumulator per attention pass; consumer paths are MSC eviction policy + KCE-mini per-block precision mode. ~0.03 mm², ~15 verification tests.

**Decision:** **Add as add-on 1.** *Confirmed Phase 0.3.*

**Open question:** Per-block vs per-token granularity. The paper allows either; per-block is silicon-cheaper (2 B per 16 tokens vs 2 B per token = 16× compression on the metadata). Lambda chooses per-block.

**Notes for visual rep:** "TIU: 256 B SRAM holding 128 × 16-bit importance scores; updated by VecU softmax broadcast; consumed by MSC eviction and KCE precision-mode lookup."

---

### 5. TurboQuant (KCE-mini's algorithmic core)

**Paper:** Ashkboos et al., "TurboQuant: Optimal Scalar Codebook KV Compression", arXiv 2504.19874, ICLR'26.

**What it claims:** Walsh-Hadamard rotation + Lloyd-Max optimal scalar codebook at 3-bit per element + per-group magnitude scale. At 32-point Hadamard: 3.5 bpe effective, 4.57× compression vs FP16, quality-neutral on LongBench. At smaller Hadamard sizes: higher effective bpe due to per-group overhead.

**Lambda status:** ✓ KCE-mini implements 16-point variant. 16 elements × 3 codebook bits + 16-bit FP16 group scale = 64 bits per 16 elements = 4.0 bpe → 4.0× compression vs FP16. Verified by re-derivation 2026-05-14.

**Hardware implication for Lambda:** 16-pt Hadamard butterfly (64 add/sub, 4 stages × 8 pairs) + 8-centroid Lloyd-Max classifier (7 comparators × 16 lanes) + bit-pack. Zero multipliers on either encode or decode path. 0.08 mm².

**Decision:** Keep as KCE-mini's primary mode. *Confirmed.*

**Open question:** Asymmetric K3V2 mode (K @ 4.0 bpe, V @ 3.0 bpe avg 3.5 bpe → 4.57× compression). Paper endorses; production deployments (0xSero/turboquant on vLLM) ship with this. Confirmed as a CSR-selectable mode in `arch.yml`.

**Notes for visual rep:** "KCE-mini: 16-pt Hadamard → Lloyd-Max 8-centroid → bit-pack. Five CSR modes: TurboQuant 3-bit (primary), Hadamard-INT4 (linear fallback), Asymmetric K3V2 (production), FP4 codebook (NVFP4 levels), FP16 bypass (debug)."

---

### 6. Sparse-blocked attention

**Papers:**
- Beltagy et al., "Longformer: The Long-Document Transformer", arXiv 2004.05150, 2020.
- Zaheer et al., "Big Bird: Transformers for Longer Sequences", arXiv 2007.14062, 2020.

**What they claim:** Replace dense Q·K^T with structured sparsity — local sliding window + a few global "sink" tokens + (BigBird) random global edges. Brings attention from O(N²) to O(N×W) where W is window size. Negligible quality loss on long-context benchmarks (PG-19, WikiHop).

**Lambda status:** ❌ not in v0.3 scope.

**Hardware implication for Lambda:** MSC's block-table indexer extends with a CSR-selectable mask pattern (dense_paged / sliding_window / sparse_blocked / local_plus_global_hybrid). The MatE Q·K^T pass reads only blocks selected by the mask. ~+0.02 mm² for the predicate + mask templates. ~10 verification tests.

**Decision:** **Add as add-on 2.** Pairs with TIU for long-context efficiency: TIU drives *which* blocks to retain (heavy-hitter), sparse-blocked drives *which* blocks to attend to in each step (spatial pattern). FlashInfer treats sparse-blocked as a first-class kernel pattern.

**Notes for visual rep:** "MSC CSR mode selects from 4 attention patterns; sparse_blocked mask is a per-layer config loaded into MSC at boot; MatE reads only blocks selected by the mask."

---

### 7. FlashInfer

**Paper:** Ye et al., "FlashInfer: Efficient and Customizable Attention Engine for LLM Inference Serving", arXiv 2501.01005, 2025.

**What it claims:** Software library that decomposes attention into a composable kernel set. Taxonomy: paged uniform, sparse structured, ragged, composite patterns. Used by SGLang, MLC-LLM, others as the underlying attention backend.

**Lambda status:** FlashInfer is software, not hardware — but its **taxonomy** is the right classification for Lambda's `attention_pattern_modes` CSR map. Adopt the four-pattern split.

**Hardware implication for Lambda:** None directly. The classification informs MSC's CSR mode design (sparse_blocked + sliding_window + dense_paged + composite).

**Decision:** Absorb taxonomy. Don't try to map FlashInfer kernels 1:1 onto silicon — they're GPU tensor-core-aware kernels and Lambda is an INT-only systolic + SIMD.

**Notes for visual rep:** "MSC.attention_pattern_modes CSR follows FlashInfer's four-pattern split."

---

### 8. Grouped-query attention (GQA)

**Paper:** Ainslie et al., "GQA: Training Generalized Multi-Query Transformer Models from Multi-Head Checkpoints", arXiv 2305.13245, 2023.

**What it claims:** Llama-3, Mistral, Gemma-2 family. N query heads share M (< N) KV heads. M=1 = MQA, M=N = MHA. Reduces KV bandwidth by N/M× vs MHA.

**Lambda status:** ✓ supported (primary). MSC handles variable kv_heads per layer; MatE Q·K^T broadcasts K across N/M query heads.

**Hardware implication for Lambda:** Already implemented. No additional work.

**Decision:** Keep. *Confirmed.*

**Notes for visual rep:** "MSC.layer_config CSR specifies kv_heads per layer; MatE broadcasts compressed K across N/M query heads in attention scoring."

---

### 9. KV Cache Acceleration Survey

**Paper:** arXiv 2506.13131, 2025. (Survey of KV cache acceleration techniques.)

**Status:** highest-value paper for cross-checking compression choices vs the broader landscape. To be read in full during Phase B execution.

**Decision:** Use as the master reference for what's in scope of Lambda vs what isn't. Update this audit doc against the survey's taxonomy.

---

### 10. Etched patent (US 2024/0419516 A1)

**See:** Phase C of the plan + dedicated section in `arch.yml` after Phase C.

**Summary:** Patent describes structurally-separated systolic + self-attention circuit. Lambda's MatE is a single fabric with two dataflow modes — structurally one fabric, not two. Non-infringement read: moderate confidence; UT Austin tech transfer review scheduled.

---

## Stub sections to fill in during Phase B execution

- KVQuant (arXiv 2401.18079) — compare quality vs TurboQuant; document why TurboQuant wins for our hardware
- FlashAttention-2 (arXiv 2307.08691) — confirm our VecU microcode handles FA-2 cases
- Speculative decoding — Medusa (2401.10774), EAGLE — make explicit Lambda compat surface
- Multi-token prediction (DSV3) — make explicit
- Mistral 7B sliding-window — confirm our paged indexing covers
- Gemma-2 local+global hybrid — confirm our paged indexing covers
- Continuous batching — document why we deliberately exclude
- MoE — document why we deliberately exclude (single-session chip)
- Mamba / SSM — document why out of scope (different math)
- Oaken, Titanus, GEAR, Lexico — quick comparisons against TurboQuant

---

## How this doc evolves

- Each Tier-1 paper gets a full section (paper / claim / Lambda status / hardware implication / decision / open question / visual-rep notes).
- Each Tier-2 paper gets a 2-3 paragraph note in the relevant stub.
- The decision summary table at top is kept in sync with the per-section decisions.
- When Phase D consolidates into `arch.yml` v0.4, this doc is referenced as the audit source.
- The "Notes for visual representation" sections become the legend / annotations on the future system diagram (probably an HTML companion to `floorplan.html` showing the data-flow + mode-select structure).
