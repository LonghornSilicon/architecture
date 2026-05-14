# Lambda — Architecture Status

**Last updated: 2026-05-14 (second pass — Phase 0 mid-stream arch changes applied)**

## Change log

- **2026-05-14 (second pass):** Phase 0 arch updates applied. (a) HIF redesigned from USB-C 2.0 to **PCIe Gen3 x1 on M.2 2280 form factor** — adds +0.25 mm² area, gives 1.5 sec weight-load and standard form factor, uses vendor IP with public 16nm datasheets. (b) **ACU naming convention adopted** as the umbrella for MatE + VecU + KCE-mini (honors Chaithu's framework). (c) **TIU (Token Importance Unit) block added** — 0.03 mm², modeled on arXiv 2604.04722, drives adaptive-precision KV and H2O-style eviction. (d) **Area accounting bug fixed** — routing_overhead_buffer was silently dropped from total in earlier drafts; gross area is now honestly 4.354 mm², with a recommended shrink path landing at 4.014 mm² contingent on PHY best case + I/O ring tightening + activation buffer trim. (e) Created `docs/literature_audit.md` (frontier attention/FFN survey, scaffolded) and `docs/reconciliation_chaithu.md` (shareable critique for teammate). Plan file at `~/.claude/plans/proud-yawning-hopcroft.md`.
- **2026-05-14 (first pass):** 8 spec bugs corrected (KV math, KCE bpe, MatE accumulator, headroom claims, SRAM/buffer sizes); repo restructured to single canonical chip target (v1/v3 retired); added `STATUS.md` LPDDR5X-vs-LPDDR4X tradeoff analysis.

This is the single live entry point for Lambda's architecture state. The canonical spec is `arch.yml`; the visual reference is `floorplan.html`; the dataflow teaching doc is `dataflow_walkthrough.md`. Everything else has been cleared.

---

## 1. State in one paragraph

Lambda is a **4 mm² (2×2 mm) standalone transformer-decoder ASIC on TSMC N16FFC**, taped out via IMEC / Europractice mini@sic 2.0 (~$60–100K shuttle, $170–290K total chip cost including PHY IP). It runs **3–5B-class W4A8 LLMs** (Llama-3.2-3B, Mistral-NeMo-3B, Qwen2.5-3B, Phi-3.5-mini) at **6–8 tok/s decode in a ~2.6 W envelope** (~3.3 W peak), with TurboQuant 3-bit KV compression at 4.0 bpe in silicon. **Seven on-die functional blocks** grouped under top-level ACU/MSC/LSU/TIU/HIF: MatE 8×8 INT8×INT4 systolic, VecU 8-lane FP16/BF16 SIMD, KCE-mini 16-pt Hadamard + Lloyd-Max (the three under the ACU umbrella); MSC memory controller with vLLM-style 128-entry block table + sparse-blocked attention CSR; LSU layer sequencer; TIU entropy-based adaptive-precision driver (new 2026-05-14); HIF PCIe Gen3 x1 on M.2 2280 form factor (revised from USB-C 2.0 on 2026-05-14). Plus 0.8 MB SRAM in four banks + LPDDR5X x16 PHY (vendor IP). Tape-out target Q1 2028; demo Q3 2028; paper at DAC/ICCAD/MICRO/HotChips 2028-09.

---

## 2. Iteration history

| Date | Pivot | What we left behind | Why |
|---|---|---|---|
| **2025-12** | Project starts as LASSO on SkyWater SKY130A via Caravel | — | Free PDK + open shuttle |
| **2026-02** | LASSO design space narrows to 4 candidate architectures (A2/A3/A3+/A4) | — | KCE block emerges as the headline IP |
| **2026-03** | Pivot from SKY130 to TSMC N16FFC, codename Lambda; team retired the "BEVO" working name | LASSO (archived) | SKY130 capacity caps at ~1B-class; Caravel ring overhead at SKY130 is large; 16nm gives 28× density and FinFET energy. **KCE block carries forward intact.** |
| **2026-04** | Pivot from 25 mm² Lambda flagship to 4 mm² Lambda v2 + v1 dual-candidate at IMEC mini@sic 2.0 | 25 mm² flagship | Flagship shuttle cost ~$400-500K — unfundable on academic timeline; 4 mm² serves the same 3-4B model class at 1/6 area, 1/5 cost via LPDDR5X x16 bandwidth tier |
| **2026-04 → 05** | Three architecture candidates at 4 mm²: v1 (KV coprocessor, no LPDDR), v2 (standalone with LPDDR5X x16), v3 (all-SRAM tiny-LLM, 2-10M params) | — | Each addressed a different demo story / risk profile |
| **2026-05-13** | **Lambda v2 selected as the headline architecture and overall arch.** v1 and v3 retired. | v1, v3 | v2 is the only path that ships a demo-able standalone 3-5B transformer accelerator without requiring a CPU-runtime software stack (v1) or capping at sub-100M-param models (v3). v1's KCE-only architecture is folded into v2 via the KCE-mini block; v3's all-SRAM idea is preserved as a future low-power variant if a sponsor asks |
| **2026-05-14** | **Pre-RTL audit completed.** 8 bugs in spec corrected (see §4 below). Repo restructured to single-arch focus. | scripts/v2_design_space, archs/_shared, archs/lasso, PRDs/, roadmap.md, archs.yaml, v1/v3 YAMLs | Single source of truth before HLS work begins |

---

## 3. Current architecture summary

| Block | Area | Function |
|---|---|---|
| MatE — 8×8 INT8×INT4 weight-stationary systolic | 0.10 mm² | All GEMMs (Q/K/V proj, FFN, logits) + Q·K^T in output-stationary mode against compressed K. **INT8 × INT4 → 11-bit product (INT16 partial register inside PE) → INT24 K-axis accumulator.** Peak 128 GOPS at 1 GHz. |
| VecU — 8-lane SIMD with online softmax | 0.144 mm² | RoPE, RMSNorm, SiLU, FlashAttention-3 softmax, residual add, sampling. 1K-inst microcode. |
| KCE-mini — TurboQuant 16-pt Hadamard | 0.08 mm² | 16-pt Walsh-Hadamard butterfly (64 add/sub) + 8-centroid Lloyd-Max codebook (3-bit) + bit-pack with 16-bit FP16 scale per 16-elem group. **4.0 bpe effective → 4.0× compression vs FP16.** Five CSR-selectable modes including FP4 codebook and asymmetric K3/V2. |
| MSC — Memory Subsystem Controller | 0.18 mm² | LPDDR5X x16 controller + 4-port SRAM crossbar + 128-entry block table (vLLM-style PagedAttention in silicon) + DMA descriptor FSM. Single-session — no continuous batching, no Tier-3 eviction. |
| LSU — Layer Sequencer | 0.10 mm² | In-order RISC, 32-instruction ISA, 4 KB microcode RAM holding pre-compiled model schedule. Single-issue scalar + vector + DMA per cycle. |
| TIU — Token Importance Unit | 0.03 mm² | Per-block 16-bit attention-entropy accumulator (256 B SRAM); drives MSC eviction (H2O-style) and KCE-mini per-block precision mode. Modeled on arXiv 2604.04722. **NEW 2026-05-14.** |
| HIF — PCIe Gen3 x1 (M.2 2280) | 0.55 mm² | PCIe Gen3 x1 endpoint (~1 GB/s sustained) for CSR access + microcode load + token I/O. M.2 form factor — slot wires 4 lanes, on-die PHY drives x1 (negotiates down). JTAG via dedicated pins. **Revised from USB-C 2.0 on 2026-05-14.** |
| **On-chip SRAM (0.8 MB)** | 0.71 mm² | kv_scratchpad 0.4 MB · activation_buffer 0.3 MB · weight_stream_buffer 0.05 MB · codebook_const_rom 64 KB |
| **LPDDR5X x16 PHY** (vendor IP) | 1.20 mm² ±0.3 | Synopsys DesignWare or Cadence Denali; NDA-gated; load-bearing area uncertainty |
| I/O ring + pads + ESD | 0.76 mm² | 100 µm ring, 2 kV HBM ESD |
| Clock + power + routing | 0.50 mm² | ~12.5% of die at 16nm |
| **GROSS TOTAL (PHY @ 1.2 mm² mid-case, no shrinks)** | **4.354 mm²** | over budget by 0.354 mm² — 2026-05-14 audit caught earlier 3.974 figure dropped routing_overhead_buffer |
| **WITH RECOMMENDED SHRINKS** (PHY @ 1.0 best-case + 80 µm ring + activation buffer 0.2 MB) | **4.014 mm²** | within 0.4% of 4.0 mm² target — contingent on Q2 2026 PHY quote |

Off-chip: 1× LPDDR5X-8533 x16 package (4–8 GB capacity, mobile-grade, ~$5–15 BoM, holds 1.5 GB W4 weights for a 3B model plus scratch). Plus the M.2 2280 carrier card with the Lambda die mounted next to the LPDDR5X package on PCB.

---

## 4. Pre-RTL audit log — bugs fixed on 2026-05-14

The 2026-05-14 audit (before HLS work begins) caught 8 bugs in the spec. All are corrected in `arch.yml` and `floorplan.html`:

1. **KV bytes/token off by ~2.3×.** Spec dropped the K+V factor of 2 in the per-token byte formula AND used flagship's 3.5 bpe instead of v2 KCE-mini's correct 4.0 bpe. Example: Llama-3.2-3B per-token-per-layer was claimed 448 B (correct value 1024 B). Capacity claims like "Qwen2.5-3B 32K context fits on-die per layer" propagated from this error.

2. **"Qwen2.5-3B 32K on-die" claim was wrong.** With corrected math, 32K context for any v2 target model requires per-layer KV well beyond the 0.4 MB scratchpad. Reframed: **32K is serviceable via LPDDR streaming at ~24 ms/tok overhead** (Qwen2.5-3B 2-head layout). Qwen2.5-3B remains the best long-context target on Lambda due to its 4× lower per-token KV vs 8-head peers.

3. **"INT16 accumulator" in MatE was a real bug.** INT8 × INT4 → 11-bit signed product; reducing K=128 (head_dim) needs 18 signed bits — INT16 (max ±32767) saturates after ~64 accumulations in the worst case. **Corrected to INT24 K-axis accumulator** with INT16 partial-product register inside each PE.

4. **"3-5× compute headroom" was wrong.** In the bandwidth-bound regime, GOPS_needed scales with bandwidth (not model size), so headroom is **constant 1.6× across all reasonable models**. Earlier framing implied headroom grew with smaller models — fortunate phrasing of a wrong derivation.

5. **"Comfortable headroom at PHY=1.0 mm²" was misleading.** The sensitivity sweep shows the chip *exactly* fits at 1.0 MB SRAM with **+0.002 mm² headroom** — no margin for surprise. SRAM stays at 0.8 MB baseline; 1.0 MB is contingent on PHY landing ≤ 1.0 mm².

6. **weight_stream_buffer was inconsistent** (0.05 vs 0.15 MB in two sections of the same YAML). Canonical: **0.05 MB** (40× LPDDR latency-hiding minimum at 12 GB/s × 100 ns first-byte).

7. **Total SRAM was inconsistent** (0.8 / 0.85 / 1.0 MB across sections). Canonical baseline: **0.8 MB** at PHY=1.2 mm²; upgradable to 1.0 MB if PHY lands ≤ 1.0 mm².

8. **KCE-mini bpe values inconsistent** (3.5 / 4.0 / 5.3 across sections). Canonical: **4.0 bpe effective** for primary 3-bit + 16-pt Hadamard mode → 4.0× vs FP16. Derivation: 16 elem × 3 codebook bits + 16-bit FP16 group scale = 64 bits per 16 elements = 4.0 bpe. (The 3.5 bpe number from the TurboQuant paper is the 32-pt flagship value; v2's 16-pt has higher per-group overhead.)

**No architectural changes** — every fix was math, derivation, or stale-claim. Audit traceability preserved in the YAML as "earlier drafts claimed X" comments next to each correction.

---

## 5. LPDDR5X x16 vs LPDDR4X x16 — the real tradeoff

You asked whether to consider Cadence LPDDR4X over Synopsys/Cadence LPDDR5X to get area breathing room + better public datasheets. **My read: it's a defensible Plan B but should not be the primary choice yet.** Here's the math.

### The two options side-by-side

| Property | **LPDDR5X x16 (current baseline)** | **LPDDR4X x16 (Cadence fallback)** | Delta |
|---|---|---|---|
| Peak bandwidth (8533/4266 Mbps × 16/8) | 17 GB/s | 8.5 GB/s | ½× |
| Sustained at 70% | **12 GB/s** | **6 GB/s** | ½× |
| PHY area at 16nm | ~1.2 mm² (NDA est.; ±0.3 swing) | ~1.0 mm² (~±0.15 swing) | −0.2 mm² + tighter variance |
| Power (mW/Gbps × Gbps sustained) | 7.5 × 96 = **0.72 W** | 12 × 48 = **0.57 W** | −0.15 W (lower BW → lower power) |
| Largest model at 5 tok/s ceiling | **4.8B** | **2.4B** | **½× the model class** |
| Comfortable model class (8 tok/s) | 3–4B (Llama-3.2-3B, Mistral-NeMo-3B) | 1–1.5B (Llama-3.2-1B, Qwen2.5-1.5B) | 2× class drop |
| Cadence public collateral at 16nm | thin (NDA-only) | **thick** (reference designs, app notes, Linley reports) | major asymmetry |
| Synopsys public collateral at 16nm | thin | thick | same asymmetry |
| First-FinFET-PHY risk for the team | **high** (R-Lv2-01) | lower — LPDDR4X has been shipping at 16nm since ~2018 with documented references | major de-risk |
| Area headroom at 4 mm² (post-Phase-0, with PCIe + TIU) | −0.354 mm² gross → +0.014 mm² after shrinks (PHY best case) | **−0.154 mm² gross → +0.046 mm² after shrinks** (LPDDR4X PHY at 1.0 mm² instead of LPDDR5X at 1.2 mm² saves 0.20 mm²) | LPDDR4X gives ~0.2 mm² more breathing room — the load-bearing argument |
| Decode regime | bandwidth-bound everywhere | bandwidth-bound everywhere | same |
| Compute headroom over BW floor | 1.6× | 3.2× | LPDDR4X leaves compute idle |

### How to think about it

There are really three axes:

**(a) Model class.** 4.8B vs 2.4B is the load-bearing difference. At 4.8B you can demo Llama-3.2-3B, Mistral-NeMo-3B, Qwen2.5-3B at 6-8 tok/s — recognizable, deployable models. At 2.4B you're capped at Llama-3.2-1B / Qwen2.5-1.5B / Phi-3-mini-1.3B — still useful but the headline pitch changes from "3B LLM on a 4 mm² chip" to "1B LLM on a 4 mm² chip." The 1B class is also where mobile NPUs (Apple, Qualcomm) commoditize; the 3B class is what differentiates an open-source academic chip from a Snapdragon/A-series NPU.

**(b) PHY risk.** LPDDR5X x16 at 16nm has fewer public reference designs than LPDDR4X at 16nm. The vendor will quote both confidently, but the team's *first FinFET PHY* tape-out is concentrated risk no matter who quotes. LPDDR4X has demonstrably shipped at 16nm in multiple academic and commercial parts; LPDDR5X x16 at 16nm is less well-documented in the open literature. If the team doesn't have or can't recruit a senior FinFET PD engineer with DDR PHY experience, the LPDDR5X risk is real.

**(c) Area.** LPDDR4X frees ~0.2 mm² that can go to SRAM (1.0+ MB feasible) or to a 12×12 MatE (180 GOPS, useful at lower BW). The chip becomes objectively easier to floorplan with comfortable margins instead of zero-headroom.

### My recommendation

**Don't pre-commit. Get both quotes in parallel.** Specifically:

1. **Synopsys + Cadence LPDDR5X x16 quote** (the primary). Two vendors so you have leverage and comparison.
2. **Cadence LPDDR4X x16 quote in parallel** (the explicit Plan B). The marginal effort to ask for this alongside is low and the data is decisive.

Then apply this decision rule:

- **If LPDDR5X x16 quote ≤ 1.25 mm² with a senior FinFET PD engineer in-place by Q3 2026 → go LPDDR5X.** The 3-5B model class is the publishable story.
- **If LPDDR5X x16 quote > 1.35 mm², OR no senior FinFET PD engineer is available → go LPDDR4X.** Recover the 0.2 mm² of breathing room and the public-collateral certainty. Reframe headline as "first open-source academic standalone 1-2B transformer accelerator at 4 mm²" — still a publishable first.
- **In the middle (1.25 < quote ≤ 1.35) → faculty/sponsor call.** Weigh "publish a 3B-class chip" against "publish a chip that taped out clean."

The case for LPDDR4X is *risk and certainty*, not *intrinsic preference*. The case for LPDDR5X is *model class and headline story*. Both are defensible; the data gates the decision.

### One thing to also try if going LPDDR4X

If you do go LPDDR4X, the model-class loss can be partially recovered via:
- **W3 weight quantization** (3-bit weights instead of 4-bit). Recent ICLR'26 results (TurboQuant, QuaRot) show 3-bit weights are usable for 3-4B-class with minor MMLU loss. Doubles the model class on the same bandwidth → 2.4B → ~4B at 5 tok/s on LPDDR4X. But it's not yet a sweet spot the same way W4A8 is.
- **Asymmetric K3/V2 KV compression** (already in the spec as a CSR mode). Frees more on-die KV capacity, less help on bandwidth.
- **Speculative decoding** (architecturally compatible; host coordinates draft tokens). 1.5–2× effective tok/s for the same bandwidth.

So even on LPDDR4X, "3-4B at 5 tok/s with aggressive quant + spec decode" is reachable. But it stacks more research risk.

---

## 6. Open questions blocking progress

In strict order of how much they gate the next decision:

1. **IMEC / Europractice mini@sic 2.0 quote for 4 mm² N16FFC.** Email `eptsmc@imec.be` price-request form. Single most pressing number. *Owner: architecture lead + faculty advisor. Deadline: 2026-05.*

2. **LPDDR PHY quotes — three at once.** Synopsys LPDDR5X x16, Cadence LPDDR5X x16, Cadence LPDDR4X x16 — all at 16nm. Pull the trigger on the LPDDR4X-vs-LPDDR5X decision per §5. *Owner: architecture lead. Deadline: 2026-06.*

3. **Senior FinFET PHY PD engineer recruited (or partnered).** Hard prerequisite for LPDDR5X path. *Owner: architecture lead + faculty advisor. Deadline: 2026-07.*

4. **Demo target model locked.** Llama-3.2-3B vs Mistral-NeMo-3B vs Qwen2.5-3B. Run Python golden-model quality eval (MMLU, LongBench) at W4A8 + TurboQuant 4.0 bpe. *Owner: ML student. Deadline: 2026-07.*

5. **Tool-ramp test chip at IMEC mini@sic.** Trivial inverter ring oscillator to clear DRC/LVS in Cadence Innovus + Calibre flow before Lambda RTL begins. *Owner: PD lead. Deadline: 2026-09.*

6. **HLS C++ implementation begins in `src/`.** Cadence Stratus HLS as the synthesis path. MatE PE and KCE-mini Hadamard butterfly are the long poles — start there. Python golden model in parallel for bit-exact reference. *Owner: RTL lead + ML student. Deadline: 2026-08 for first PE.*

---

## 7. Frontier work to plan next

These are the architecture deep dives queued behind the bug fixes and cleanup. They are scoped in plan-mode (see the next interaction):

- **Critique of teammate's adaptive-precision-attention work** (Precision Controller + MAC Array specs at `LonghornSilicon/adaptive-precision-attention`). The work assumes a heterogeneous INT8/FP16 MAC array with a per-tile precision gate; Lambda's architecture commits to INT8 × INT4 × INT3 (TurboQuant) without an FP16 path in MatE. Reconcile or fork.

- **Attention/FFN mechanism deep dive.** PagedAttention (vLLM), FlashAttention-2/3, sparse-blocked attention, MLA (DeepSeek), GQA, MQA, batched-grouped attention. Lambda currently commits to FA-3 + paged-attention + GQA/MQA via MSC. Audit each for what's actually frontier vs what's reasonable middle ground; identify hardware implications.

- **Etched patent (US 2024/0419516 A1) implications.** Etched splits the systolic array (no previous-token dependency) from a separate self-attention circuit (uses previous-token data). Lambda's MatE multiplexes both via dataflow mode. Is the patent's split right at our scale (4 mm², 64 PEs), or does multiplexing dominate at this die size? Hardware schedule analysis required.

- **Research corpus alignment.** Cross-check our 8 KCE modes against TurboQuant, QuaRot, RotateKV, KVQuant, Oaken, Titanus, GEAR, Lexico. Identify the *next-gen mode* worth adding as a CSR option for the chip's research narrative.

---

## 8. The two non-architectural risks that still worry me

- **IMEC mini@sic 2.0 actual pricing for 4 mm² N16FFC.** Pricing is non-public; ranges are academic-discount-tier estimates. A $120K or $150K return would not kill the project but would change the funding plan.

- **The LPDDR PHY tape-out itself.** First FinFET-era PHY for the team. Senior PD engineer or partner is a hard prerequisite (R-Lv2-01). LPDDR4X fallback (§5) materially de-risks but at the cost of model class.

Both are recoverable; neither is a kill. The architecture is sound.

---

*Maintained as a live document. Append dated change-log entries when state shifts.*
