# Architecture Status — 2026-04-26

**Where we are, what's verified, and the choice between Lambda v1 and Lambda v2 at 4 mm² via IMEC.**

This document is the single live entry point. It supersedes any earlier "where we left off" notes.

---

## 1. State of the chip in one paragraph

Lambda is a 4 mm² (2×2 mm) transformer-related ASIC on TSMC N16FFC, taped out via **IMEC / Europractice mini@sic 2.0** as the primary path (with Muse Semiconductor as a US fallback). The realistic budget is **$60-100K shuttle** (mini@sic academic-discount path). Two architecture candidates are spec'd at this same area and cost — the team picks one:

- **Lambda v1 (conservative):** [`archs/lambda/Lambda_v1_4mm2.yaml`](archs/lambda/Lambda_v1_4mm2.yaml) — KV cache + compressed-domain attention coprocessor. No LPDDR, no PCIe. Pairs with a host CPU/GPU running the rest of the model. Lower verification load (~140 effective new tests, ~22 person-months), simpler PD, but undemonstrable without a host-side software stack (~3-6 person-months of integration work).
- **Lambda v2 (ambitious):** [`archs/lambda/Lambda_v2_4mm2.yaml`](archs/lambda/Lambda_v2_4mm2.yaml) — standalone end-to-end mini-accelerator with **LPDDR5X x16** (12 GB/s sustained), 8×8 MatE, KCE-mini, ~1.0 MB SRAM. **Targets 3-5B-class models on-die** (Llama-3.2-3B at 8 tok/s, Mistral-NeMo-3B at 8 tok/s, Phi-3.5-mini at 6 tok/s, up to ~5B at threshold 5 tok/s) in a 4 W envelope. Higher verification load (~180 effective new tests, ~28 PM), real LPDDR PHY integration risk, but ships as a complete demo-able chip running real 3-4B-class models. **Same model class as the abandoned 25 mm² flagship was targeting at 7-8B — in 1/6 the area at 1/5 the cost.** A v2-stretch with LPDDR5X x32 PHY (4.4 mm² die, ~$90-130K) extends to 7-8B class at compute-bottlenecked 5-6 tok/s.

Same 4 mm² budget. Same shuttle cost. Different chip.

---

## 2. The choice — v1 vs v2 at the same 4 mm² budget

| Property | Lambda v1 (conservative) | **Lambda v2 (ambitious)** |
|---|---|---|
| Role | KV/attention coprocessor (pairs with host) | Standalone end-to-end accelerator |
| Off-chip DRAM | none (host owns DRAM) | 1× **LPDDR5X x16** (~12 GB/s sustained) |
| Host interface | USB-C 3.2 Gen 2x2 (~4 GB/s for KV traffic) | USB 2.0 / minimal SerDes (~60 MB/s for tokens only) |
| MatE compute | none (host runs MatE) | 8×8 (64 PEs, 0.13 TOPS at 1 GHz) |
| KCE | full 32-point Hadamard, 8-centroid Lloyd-Max | mini 16-point Hadamard, 8-centroid Lloyd-Max |
| SRAM | 1.5 MB KV scratchpad | 1.0 MB total (0.5 KV / 0.3 act / 0.15 weight / 0.05 ROM) |
| Target workload | accelerate KV-bound CPU-only LLM inference | **standalone 3-5B-class transformer decode** |
| **Largest reasonable model** | n/a (host owns the model) | **5B class at 5 tok/s threshold** (Llama-3.2-3B / Qwen2.5-3B / Mistral-NeMo-3B at 8 tok/s comfortable; Phi-3.5-mini 3.8B at 6 tok/s) |
| Demo story | "speeds up CPU-only llama.cpp 4-8×" | "3-5B LLM ASIC running standalone at 4 W" |
| Power | ~3 W | ~4 W |
| Verification load | ~140 effective tests, ~22 PM | ~180 effective tests, ~28 PM |
| LPDDR PHY integration risk | none | high (vendor IP at 16nm, NDA-gated) |
| Software stack required to demo | yes (~3-6 PM CPU-stack integration) | no (chip self-demos) |
| Research first | "first silicon TurboQuant + compressed-domain attention" | "first open-source standalone 3-5B transformer accelerator at 16nm" |
| **Stretch option** | n/a | **LPDDR5X x32** PHY → 7-8B-class at 5-6 tok/s (compute-bottlenecked); +0.4 mm² die, +25% shuttle cost |

**The decision frame:** v1 minimizes silicon risk but pushes the demo-blocker into software. v2 absorbs more silicon risk but ships a complete demo-able chip. Both are real research firsts; they target different markets and tell different stories.

If software engineering is in place → v1's lower verification load is decisive.
If standalone demo without software is the priority → v2.
If unsure → STATUS recommends **v1** because LPDDR PHY integration at 16nm is the team's first FinFET tape-out and the risk is concentrated.

---

## 3. The FP4 question, resolved

You flagged confusion: the [`roadmap.md`](roadmap.md) says you're optimizing an **FP4 × FP4 multiplier circuit** (T-01, currently at 74 gates and shrinking via your AlphaEvolve loop), but Lambda specs say MatE is INT8 × INT4 with no FP4 multiplier. So which is it?

**Both. They are different uses of "FP4."**

| Mode | What it is | Where it lives | Hardware needed | Status in Lambda |
|---|---|---|---|---|
| **FP4 as a fixed codebook** | The 8 NVFP4 magnitude values `{0, 0.5, 1, 1.5, 2, 3, 4, 6}` stored as a 64-byte ROM. K/V quantized to nearest codebook entry. Decode is LUT lookup, no multipliers. | KCE (KV compression block) | 64-byte alternative ROM contents + 1-bit CSR mode select. **No new logic.** | **Available in both v1 and v2 as a CSR mode of KCE alongside TurboQuant 3.5b and Hadamard-INT4.** Free, ~5 verification tests. See [`archs/_shared/algorithms.yaml`](archs/_shared/algorithms.yaml) `fp4_e2m1_as_codebook`. |
| **FP4 as an arithmetic format** | Real E2M1-FP4 × E2M1-FP4 multiplier with exponent alignment, normalization, subnormal handling. ~3× gates of an INT4 × INT4 multiplier. The thing T-01 is optimizing. | MatE (PE multiplier) | A whole new multiplier datapath. v1 has no MatE; v2's MatE is INT8 × INT4. | **NEITHER v1 NOR v2 contain an FP4 multiplier.** The T-01 work is for the Etched contract, and the methodology is the template for Lambda's other circuit-level optimizations (T-02 INT8×INT4 PE mul, T-04 fused MAC, etc.) that DO appear in Lambda v2. |

The roadmap T-01 work is justified for Lambda *as research-methodology infrastructure*, not as a v1/v2 silicon component. The 74-gate FP4 multiplier itself does not appear in either Lambda v1 or v2.

---

## 4. Why 4 mm² (and not 9, 16, or 25)

The shuttle cost gates the architecture. Per IMEC / Europractice and Muse data points:

| Die size | Approximate shuttle cost | Verdict |
|---|---|---|
| **4 mm²** | **~$60–100K via IMEC / ~$75K via Muse** | **Realistic budget. THE TARGET.** |
| 9 mm² | ~$135-200K via IMEC / ~$169K via Muse | Outside budget unless major sponsor lands |
| 16 mm² | ~$240-360K | Outside academic-shuttle budget |
| 25 mm² | ~$375-550K | Out of the question |

The earlier 25 mm² "flagship" target was abandoned; its specifications were superseded by the current 4 mm² Lambda v2 (which serves the same 3-4B model class at 1/6 the area and 1/5 the cost). See `archs/lambda/Lambda_v2_floorplan.html` for the current floorplan and full specifications.

---

## 5. Validation status — what's verified vs uncertain

### Verified (well-cited or cross-checked)

- **TurboQuant ICLR'26 quality at 3.5 b/elem** — multiple open-source implementations (0xSero/turboquant w/ vLLM, AmesianX/TurboQuant for llama.cpp, scos-lab/turboquant). Quality-neutral on LongBench and Needle-in-Haystack across Gemma and Mistral models.
- **TSMC N16FFC density** (28.2 MTr/mm², ~1.25 MB/mm² HD SRAM 1-port) — published in WikiChip and IEEE 2016 references.
- **W4A8 sweet spot for small-LLM inference** per ACL'25 (`Give Me BF16 or Give Me Death`, arXiv 2411.02355).
- **NVFP4 vs MXFP4 specs** — Blackwell-native; open-source Transformer Engine + LLM Compressor 0.9.0 (Jan 2026). A non-NVIDIA NVFP4 silicon would be a research first, but neither v1 nor v2 contain that mode in MatE — the roadmap T-01 work is the building block for a future revision.
- **Roofline math** — verified by hand against TPU scaling-book methodology.

### Load-bearing uncertain (real risk; needs action)

- **IMEC / Europractice mini@sic 2.0 actual pricing for 4 mm² N16FFC.** Pricing is non-public; ranges based on academic-discount tier. *Action: direct quote via `eptsmc@imec.be` price-request form.*
- **LPDDR4X x16 PHY area at 16nm** (only relevant for v2). Estimated 1.0 mm²; could be 1.2-1.5. A 0.5 mm² overrun on a 4 mm² die is 12.5% — meaningful. *Action: written quote from Synopsys + Cadence in Q2 2026.*
- **Whether 1 GHz is hittable in commercial flow with this team's first FinFET PD attempt.** Test chip Q3 2026 will tell. 800 MHz fallback is built into both v1 and v2 specs.
- **Software stack timeline (v1 only).** v1 is undemonstrable without ~3-6 PM of CPU-stack integration work.

---

## 6. What's been corrected (so future-you doesn't reintroduce these)

- ❌ "Target 25 mm² flagship at $50-150K" → ✓ "4 mm² target at $60-100K via IMEC mini@sic 2.0" (the prior $50-150K estimate for 25 mm² was 3-4× low; realistic was $400-500K, which is unfundable)
- ❌ "Lambda is 2.5× more energy efficient than H100" → ✓ "Lambda is comparable on energy/token; pitch is absolute power and BoM cost"
- ❌ "Prefill 4K in 1.5 sec" (units error) → ✓ "Prefill 4K is unattainable at this die size; recommended interactive prompt ceiling 128-256 tokens for v2"
- ❌ "Three tiers: pico/mini/flagship" → ✓ "One die size (4 mm²); two architectural alternatives (v1 conservative vs v2 ambitious) with v2 supporting 3-5B models via LPDDR5X x16"
- ❌ "Lambda v1 vs Lambda v2" referring to chip generations → ✓ "v1 vs v2 are two architecture candidates at the same 4 mm² budget"
- ❌ "Muse Semiconductor as primary shuttle vendor" → ✓ "IMEC / Europractice mini@sic 2.0 primary; Muse fallback"

---

## 7. Concrete next moves

In strict order:

1. **Get IMEC / Europractice quote for 4 mm² N16FFC mini@sic 2.0.** Email `eptsmc@imec.be` price-request form. Single most pressing number. *Owner: architecture lead + faculty advisor. Deadline: 2026-05.*
2. **Decide v1 vs v2.** Based on (a) the IMEC quote, (b) whether software engineering is in place for v1's CPU-stack integration, (c) team's tolerance for LPDDR PHY integration risk for v2. *Owner: architecture lead + faculty advisor. Deadline: 2026-06.*
3. **If v2: get LPDDR5X x16 PHY quote** from Synopsys + Cadence at 16nm. Lock the load-bearing area uncertainty (1.2 mm² estimate, ±0.3 mm² real swing) before floorplan freeze. *Owner: architecture lead. Deadline: 2026-06.*
4. **Q3 2026 tool-ramp test chip.** Inverter ring oscillator at N16FFC through IMEC/Muse. Clears DRC/LVS in commercial flow before Lambda RTL begins. *Owner: PD lead — biggest 2026 staffing need.*
5. **Begin Python golden model now** in parallel with hardware quotes. Single artifact that proves the chosen v1 or v2 architecture runs the target workload before any RTL exists. Bit-exact target for KCE and online softmax verification. *Owner: RTL lead + ML student.*

---

## 8. Architecture frontier — what to push beyond v1/v2 baseline

Both v1 and v2 have headroom for incremental improvements that don't change the chip class:

1. **Asymmetric K=3-bit / V=2-bit TurboQuant mode in KCE** (free upgrade, ~5 verification tests). Production deployments (0xSero/turboquant on vLLM) ship with K=3-bit, V=2-bit because attention is more sensitive to K precision than V. Average bpv ~2.5 → ~6× compression vs FP16. **Add to both v1 and v2 v0.3 specs.**

2. **FP4 codebook mode in KCE** (already specified as optional CSR mode). Lets the chip do compressed-domain attention scoring against FP4-quantized K — a direct comparison vs NVFP4 that no Blackwell silicon can do at this scale. **Free differentiator for the paper.**

3. **Speculative decoding hardware support** (architecturally just batched-N decode). Already mentioned in v1's recommendation block. Free if continuous-batching dispatcher exists; v2 doesn't have it (single-session) but v1's MSC could.

These are paper-strengthening moves at near-zero silicon cost. Add to v0.3 of whichever YAML the team commits to.

---

## 9. Honest read

The architecture is real. The numbers (after corrections) are honest. The 4 mm² budget forces hard choices:
- v1 sacrifices end-to-end demo for lower verification risk
- v2 sacrifices verification headroom and adds LPDDR PHY risk for end-to-end demo
- Neither is a transformer accelerator at 7-8B class — both target either CPU-paired KV acceleration (v1) or 0.25-1B-class on-device inference (v2)

Both produce real research firsts; the chip is publishable either way. The question is which research first the team values more, and which they have capacity to execute.

The two non-architectural risks that worry me most:
- **Pricing reality** — IMEC mini@sic 2.0 quote could come back $80K, $120K, or higher. Direct quote needed before committing.
- **LPDDR PHY for v2** — first FinFET tape-out + LPDDR PHY integration is a real risk. This is the single biggest reason to prefer v1.

If v1 wins, the chip is straightforward to silicon, and the team's effort goes into the host-side software integration (which is fundable as a graduate research program).

If v2 wins, the chip is genuinely standalone and demo-able, but the team needs a PHY-experienced PD engineer or partner.

**Both are good paths. Pick deliberately.**

---

*Generated 2026-04-26 after pivot to IMEC + 4 mm² realistic budget. Supersedes any previous "where we left off" notes. Maintain by appending dated change-log entries.*
