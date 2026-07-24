# Attention-mechanism frontier review — Lambda fit analysis

**Date: 2026-06-10. Status: delivered (this was STATUS §7 queued item "Attention/FFN mechanism deep dive"). Author: architecture audit session.**

Every recommendation below is graded against Lambda's actual regime, not against datacenter assumptions. The regime (all numbers from `arch.yml`, audited 2026-06-10):

- **Decode is weight-bandwidth-bound.** 134.4 ms/token for Llama-3.2-3B is weight streaming; KV adds ~3 ms at 1.5K context, ~9 ms at 4K, ~78 ms at 32K. So KV-side mechanisms buy almost nothing at short context and *everything* at long context. The chip's long-context story is currently its weakest claim.
- **Compute headroom is a constant 1.6×** (76.8 effective GOPS vs 47.8 needed). Any mechanism that spends < 0.6× more compute to save bandwidth is free in wall-clock.
- **Batch 1, single session.** No batching tricks, no prefix sharing, no cross-request reuse. Mechanisms must pay off for one stream.
- **0.4 MB KV scratchpad (409 tokens/layer for the primary model), 128-entry × 16-token block table (2,048-token coverage), TIU entropy eviction, KCE-mini 4.0 bpe.**
- **MatE has no FP16 path.** Anything requiring per-tile FP16 attention fallback is architecturally excluded (this is a feature — see SageAttention evidence below).

---

## 1. Scorecard on what's already planned

| Planned mechanism | Verdict | Notes |
|---|---|---|
| GQA/MQA native | ✅ right | The entire target class (Llama-3.2, Qwen2.5, SmolLM3) is GQA. MHA (Phi-3.5) is the degenerate case. |
| PagedAttention-in-silicon (MSC block table) | ✅ right, one gap | Single-session paging is sound. Gap: 2,048-token table coverage vs the 32K streaming story — see §2, the same table can carry selection metadata. |
| "FlashAttention-3 softmax" | ⚠️ rename | What Lambda implements is the FA-2 **algorithm** (online softmax + tiling). FA-3's actual contributions (Hopper warp specialization, TMA async, FP8 with incoherent processing) don't exist on a 4 mm² ASIC. Paper should say "FlashAttention-style online softmax" — reviewers at MICRO/DAC will catch this. |
| TIU H2O-style eviction | ✅ keep, with a caveat | Eviction error and quantization error **compound** — H2O's published quality is on FP16 KV. The pre-HLS golden-model eval must test eviction × 4.0 bpe jointly, not separately. |
| KCE-mini 16-pt rotation codebook | ✅ headline IP | Unvalidated quality bet (documented in STATUS §8) but the right bet. §4 below adds two near-free insurance mechanisms. |
| Asymmetric K3/V2 | ✅ keep | Correctly re-attributed as Lambda's own extension (2026-06-10); K-more-sensitive-than-V is well supported (KVQuant, arXiv 2401.18079). |

---

## 2. The biggest miss: query-aware page selection (Quest-family) — TIER 1, recommend for v1

**What it is.** Quest (Tang et al., ICML 2024, arXiv 2406.10774): keep per-page metadata (element-wise min/max of the keys in each page), compute a cheap upper bound on each page's attention score against the current query, fetch and attend over only the top-K pages. Training-free, which is the binding requirement for an inference chip serving stock models. The 2026 literature has converged hard on this family ([training-free NSA](https://openreview.net/forum?id=sQjYtFSEuZ) reports 16× compression at 32K with 99%+ accuracy via hierarchical block-wise selection; [SALS](https://arxiv.org/abs/2510.24273) does selection in a low-rank latent space, 5.7× attention speedup).

**Why it's the single biggest available win for Lambda.** It converts long-context KV traffic from O(L) to O(k):

- At 32K context, Llama-3.2-3B KV streaming costs ~78 ms/token (drops decode to ~4.9 tok/s — at the demo threshold). With top-64-page selection: fetch 64 × 16 KB = 1 MB/layer × 28 layers / 12 GB/s ≈ **2.4 ms**, plus metadata scan (below) ≈ 5 ms, plus scoring compute ~1–2 ms → **~8–9 ms total vs ~78 ms ≈ 8× reduction in the long-context penalty** *(estimate, bounds: 5–12 ms depending on metadata precision and K)*. The 32K story changes from "at threshold" to "comfortable."
- It is **selection, not eviction** — everything stays in LPDDR, so it's quality-recoverable per query, unlike TIU eviction which is permanent. The two compose: TIU evicts the provably dead, Quest selects among the living.

**Why Lambda is unusually well-positioned to implement it.**
1. The MSC block table already pages KV at 16-token granularity — Quest's unit of selection *is* our page.
2. **The metadata can be computed by KCE for free.** KCE already sees every K vector in rotated (Hadamard) space at compress time. Min/max accumulated per page **in the rotated domain** upper-bounds rotated-Q dot products — Quest in the Hadamard domain, a side-output of the existing compress pipeline. No extra pass over the data.
3. Scoring is a small integer GEMV-like kernel: per page per KV head, Σ_i max(q_i·min_i, q_i·max_i) over 128 channels. At 32K: 2,048 pages × 8 heads × 256 ops × 28 layers ≈ 118 M ops/token ≈ 1–2 ms on MatE/VecU — paid out of the 1.6× headroom *(estimate)*.
4. Metadata does NOT need to live on-die. At INT4 min/max it's 1 KB/page/layer ≈ 6% of page size; for 32K context that's ~512 KB/layer in LPDDR, streamed for scoring at ~0.17 ms/layer aggregate. On-die cost is just a scoring buffer (~2–4 KB).

**Cost estimate:** MSC metadata path + accumulators in KCE + a TIU/VecU scoring microcode routine + CSR top-K knob. Order 0.01–0.02 mm² logic + small buffer *(estimate; logic at 16 nm is cheap — the real cost is ~10–15 verification tests and one more dataflow mode)*. **Fallback if it slips:** dense streaming path is unchanged; Quest mode is purely additive (CSR-gated), so it cannot regress the baseline.

**Risk to name:** upper-bound tightness at 3-bit compressed K (metadata computed pre-quantization in rotated space avoids most of this); page-boundary effects at 16 tokens are *finer* selection granularity than Quest's published 32–64-token pages — favorable direction.

---

## 3. Second miss: sliding-window ring-buffer mode + pinned sinks — TIER 1, recommend for v1

**The model class is moving under us.** SmolLM3-3B ships GQA + sliding-window attention; Gemma-3-4B is 5:1 local:global with a 1,024-token window (arXiv 2503.19786); Gemma-4-E2B continues the hybrid local/global pattern; GPT-OSS uses SWA + learned attention sinks ([Raschka's Jan–Feb 2026 survey](https://magazine.sebastianraschka.com/p/a-dream-of-spring-for-open-weight) confirms the trend). A 2028 demo chip that can't serve SWA models natively will be serving yesterday's architectures.

**The hardware is almost free.** A sliding window is *modular addressing over the existing block table* — a ring buffer per SWA layer. No new memory, no new datapath; a per-layer CSR (window length, is_local flag) and wraparound logic in the MSC address generator. Attention sinks (StreamingLLM, arXiv 2309.17453) are "pin page 0, never evict" — one bit in the block-table entry, and it also gives **unbounded-session streaming** for free on any model (the demo can run forever instead of dying at context limit — a demo-day insurance policy).

**Payoff:** for a 5:1 hybrid like Gemma-3-4B, only 1/6 of layers accumulate unbounded KV; total KV traffic and capacity pressure drop ~6× at long context, and the local layers' windows (1,024 tokens) get *close* to scratchpad-resident at 4.0 bpe. This composes with Quest (§2): Quest handles the global layers, ring buffers handle the local ones.

**Cost:** ~days of MSC RTL + ~5 verification tests *(estimate)*. Strongly recommend for v1.

---

## 4. Quantization-side insurance for the 4.0-bpe bet — TIER 1, near-free

The headline risk (STATUS §8) is that 16-element-block rotation-codebook quality at 4.0 bpe is unvalidated. Three cheap mechanisms de-risk it:

1. **CSR-writable codebook centroids** (vs fixed ROM). Lloyd-Max centroids calibrated per model on activation statistics are standard practice and recover meaningful quality vs fixed Gaussian-optimal centroids. The store is 16 bytes per codebook variant — making it a writable CSR register instead of ROM is approximately free and turns a silicon risk into a software knob. **Strongest single insurance available.** *(If `codebook_const_rom` already allows this, promote it to a documented contract.)*
2. **Per-page K mean-smoothing (SageAttention2 trick, arXiv 2411.10958).** Subtracting the per-block channel mean of K before quantization collapses outliers; the correction term (q·k_mean, one scalar per page per head) is added back at the row sum. SageAttention2 validated INT4 Q/K attention across model families with exactly this smoothing. Cost: one VecU subtract at compress, one scalar MAC at score. CSR-gated mode.
3. **Cite SageAttention 1/2 in the paper as published evidence that low-bit integer QK^T preserves quality.** Lambda's compressed-domain INT8×INT3 scoring claim currently stands alone; SageAttention's INT8 (arXiv 2410.02367) and INT4 (2411.10958) attention kernels running quality-neutral across LLM benchmarks is the closest published support in existence. This costs a paragraph and materially strengthens Contribution 2.
4. **Watch, don't adopt yet: pre-RoPE K quantization** (KVQuant's trick — quantize K before positional rotation, apply RoPE at score time). It conflicts with compressed-domain scoring (RoPE-at-score costs per-score compute) — note it as the known alternative if post-RoPE K distributions turn out to be the quality bottleneck in the golden-model eval. The eval should log pre- vs post-RoPE K statistics so this is a data-driven decision.

---

## 5. Architect hooks now, implement later — TIER 2

- **Per-head KV policy (DuoAttention, arXiv 2410.10819).** ~Half of heads in served models are "streaming" heads needing only window+sink; the rest are retrieval heads needing full KV. Offline profiling (training-free in deployment) yields a per-head bitmap. Hardware cost: per-head window/full flag in MSC — a few CSR bits on top of §3's ring-buffer machinery. Multiplies with everything (halves Quest's scoring work AND the streaming traffic). v1 if §3 lands, else v2.
- **MLA decode path (absorbed-matmul form).** DeepSeek-style Multi-head Latent Attention stores one ~256–512-dim latent per token instead of per-head K/V — and a real target exists in-class: **MiniCPM3-4B** (openbmb, MLA, 4B). The absorbed form (score Q against W_UK-projected latents) is a GEMV restructure MatE can do; no new datapath, but a new LSU schedule and scoring mode. The 2026 latent-space trend (SALS, MLA adoption in new releases) says this family grows. **v2 stretch, but reserve the CSR/schedule encoding space now** — retrofitting a KV layout enum is much cheaper than retrofitting silicon.
- **Block-table scope note:** with §2's metadata-in-DRAM design, the 128-entry on-die table remains the *resident-set* map while selection operates over the full LPDDR-backed context. Document the two-level model explicitly in `arch.yml` (on-die table = cache of hot pages; DRAM metadata = full-context index).

---

## 6. The strategic risk nobody's pricing in: hybrid-linear takeover of the 3B class

Qwen3-Next (Gated DeltaNet hybrid), Granite 4.0, Falcon-H1, Zamba2-2.7B, RWKV-7 2.9B, MiniMax — and the Jan–Feb 2026 release wave continues the trend ([hybrid architectures consistently outperform homogeneous ones](https://arxiv.org/html/2510.04800); [Liger-style GRM+SWA hybrids](https://arxiv.org/pdf/2503.01496)). **There is a real probability that by tape-out (Q1 2028), the frontier open 3B model is a softmax-attention/linear-recurrence hybrid.** Lambda is betting on pure-transformer decode.

Pressure-testing rather than panicking:
- **The bet is still defensible**: Llama/Qwen/Phi-class pure transformers will remain deployed and reproducible; an academic demo doesn't need the newest architecture, it needs a *recognizable* one.
- **The mitigation is already on-die**: linear-attention decode per token is a handful of GEMVs (MatE-shaped) plus elementwise gating/state update (VecU-shaped). State precision (FP16/FP32 recurrent state, ~64–256 KB/layer class-dependent) is the real question, and the activation buffer is the candidate home. A hybrid model's SWA layers run on §3's ring buffers natively.
- **Action:** one ML-student-week, post golden model: paper-map Zamba2-2.7B or SmolLM-class hybrid decode onto MatE/VecU/LSU microcode and find the single blocking gap (likely state precision or a nonlinearity in VecU's LUT set). Knowing the gap in 2026 is cheap; discovering it in 2028 is not. Log as a named risk in STATUS §8.

---

## 7. Explicitly NOT recommended (and why)

| Mechanism | Why not |
|---|---|
| NSA (arXiv 2502.11089), MoBA (2502.13189), DeepSeek DSA | **Trained** sparse attention — requires models trained with it. Wrong side of the training-free line for an inference chip. Revisit only if an open ≤4B model ships with one (NSA's blockwise structure would map beautifully onto our 16-token pages — watch this). Quest (§2) is the training-free member of the same family. |
| CLA / YOCO cross-layer KV sharing | Model-side decision; no open small model of note uses it. Zero hardware prep needed — if such a model appears, it just means *fewer KV writes*, which existing hardware handles. |
| Latent low-rank re-projection of stock models (SALS-style as a chip feature) | Requires per-model offline SVD + an extra reconstruction matmul per selected token; the quality/complexity trade isn't proven at 3B scale. The MLA hook (§5) covers the latent future where the *model* provides the latent natively. |
| MInference / XAttention-style sparse **prefill** | Pays off at ≥8–32K prompts. Lambda's interactive prompt ceiling is 256–512 tokens; prefill sparsity optimizes a regime the chip explicitly doesn't target. |
| Per-tile FP16 fallback (adaptive-precision MAC arrays) | Re-introduces the 0.4 mm² FP16 fabric the architecture's headline deliberately deleted; SageAttention's results (§4.3) say it isn't needed. This is the Chaithu-reconciliation fork point — Lambda's answer stands. |

---

## 8. Action list (proposed; nothing committed)

| # | Action | Tier | Est. cost | Owner | Gate |
|---|---|---|---|---|---|
| 1 | Quest-mode page selection: KCE min/max side-output (rotated domain) + DRAM metadata + VecU/MatE scoring + CSR top-K | 1 | ~0.01–0.02 mm², ~10–15 verif tests *(est.)* | arch + RTL | spec review |
| 2 | MSC ring-buffer SWA mode + sink-pin bit | 1 | ~5 verif tests *(est.)* | RTL | spec review |
| 3 | Codebook centroids CSR-writable; per-model calibration in golden model | 1 | ~free | RTL + ML | none |
| 4 | K mean-smoothing CSR mode (SageAttention2-style) | 1 | ~free | RTL + ML | golden-model A/B |
| 5 | Paper: FA-3 → "FlashAttention-style online softmax"; add SageAttention 1/2 as compressed-scoring evidence | 1 | text | paper | none |
| 6 | Golden-model eval matrix: add eviction×quant compounding, pre/post-RoPE K stats, 16-pt-WHT vs 128-dim-random-rotation ablation | 1 | ML time | ML student | — |
| 7 | Per-head window/full policy bits (DuoAttention) | 2 | few CSR bits | RTL | after #2 |
| 8 | MLA absorbed-decode CSR/schedule encoding reserved; MiniCPM3-4B config pull | 2 | spec only | arch | v2 |
| 9 | Hybrid-linear (Zamba2/SmolLM-hybrid) paper-mapping exercise; STATUS §8 risk entry | 2 | 1 wk ML | ML student | post-golden-model |

**Sources:** Quest [arXiv 2406.10774](https://arxiv.org/abs/2406.10774) · training-free NSA [OpenReview](https://openreview.net/forum?id=sQjYtFSEuZ) · SALS [arXiv 2510.24273](https://arxiv.org/abs/2510.24273) · SageAttention [2410.02367](https://arxiv.org/abs/2410.02367) / SageAttention2 [2411.10958](https://arxiv.org/abs/2411.10958) · StreamingLLM [2309.17453](https://arxiv.org/abs/2309.17453) · DuoAttention [2410.10819](https://arxiv.org/abs/2410.10819) · Gemma 3 [2503.19786](https://arxiv.org/abs/2503.19786) · NSA [2502.11089](https://arxiv.org/abs/2502.11089) · MoBA [2502.13189](https://arxiv.org/abs/2502.13189) · KVQuant [2401.18079](https://arxiv.org/abs/2401.18079) · H2O [2306.14048](https://arxiv.org/abs/2306.14048) · hybrid-architecture analysis [2510.04800](https://arxiv.org/html/2510.04800) · Liger [2503.01496](https://arxiv.org/pdf/2503.01496) · 2026 release survey [Raschka](https://magazine.sebastianraschka.com/p/a-dream-of-spring-for-open-weight) · MiniCPM3-4B [HF](https://huggingface.co/openbmb/MiniCPM3-4B). Items marked *(est.)* are estimates with stated bounds, not citations.
