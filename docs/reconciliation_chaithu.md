# Reconciling `adaptive-precision-attention` with Lambda's `arch.yml`

**Authors:** Lambda architecture team (Alan Schwartz, UT Austin)
**Audience:** Chaithu Talasila + faculty advisor
**Date:** 2026-05-14
**Status:** open for response

---

## What this document is

A peer-to-peer technical reconciliation of `LonghornSilicon/adaptive-precision-attention` (your work on the Precision Controller + MAC Array + the broader four-block framework: ACU, KV Cache Engine, Token Importance Unit, Memory Hierarchy Controller) against Lambda's current `arch.yml` spec — the canonical chip target for our 4 mm² TSMC N16FFC tape-out via IMEC mini@sic 2.0.

There's a real architectural choice that needs to be made deliberately, and the path Lambda has committed to differs from yours in one important way. This doc lays out what we agree on, where Lambda has chosen differently, and what we'd like to absorb from your work.

It's also intended as the starting point for a live conversation with our faculty advisor. Honest, constructive, technically grounded. No corrective tone intended.

---

## What's strong in your work

Multiple pieces deserve credit and are being absorbed into Lambda:

1. **The three-language reference template** (`precision_controller_ref.{hpp,cpp,py}` + `mac_array_ref.{hpp,cpp,py}`). The "C++ class ↔ extern \"C\" ↔ Python — all three pass identical test vectors" property is exactly the verification shape Lambda's `src/golden/` will adopt. We're modeling our golden-model template on yours. This is genuinely the right pattern for bit-accurate spec → implementation.

2. **The bit-accurate verification methodology.** "143/143 RTL replay tiles match" is the standard Lambda's HLS work will hit. We've set the same bar.

3. **The ISA + memory-map design pattern** (AXI-Lite for control, AXI-Stream for data, INFO_* registers for synthesis-time constants). This is the right shape for an FPGA prototype if we do a Zynq UltraScale+ intermediate step before silicon.

4. **The compiler binding patterns sketch** (MLIR / TVM Relax / ONNX / custom IR). Useful when Lambda gets to the toolchain question; we'll reference this.

5. **The phased integration plan** (Phase 0 reference → Phase 1 FPGA → Phase 2 multi-block FPGA → Phase 3 silicon). We're mirroring this in Lambda's roadmap.

6. **The naming convention — ACU.** Adopted into Lambda as the umbrella for our compute fabric. See §3 below.

7. **The TIU concept.** Adopted into Lambda as a real silicon block, grounded in arXiv 2604.04722. See §3 below.

The reference-model + verification + ISA scaffolding is genuinely well-thought-out engineering. That work transfers.

---

## The architectural decision Lambda has made

Lambda commits to a different quantization premise than your Precision Controller assumes, and that premise drives the rest of the chip's design. Here's the diff:

**Your Precision Controller's premise:** outlier attention tiles need higher precision (FP16) to retain quality; route them dynamically per-tile based on the entropy-equivalent ratio `max(|s|) × N > Σ(|s|) × 10`. The MAC Array has both an INT8 path and an FP16 path; tiles flow to whichever the precision controller selects.

**Lambda's premise:** rotation-codebook compression (TurboQuant, arXiv 2504.19874) handles outlier attention tiles **at write-time**, not at read-time. Specifically:

- Each K/V vector is multiplied by a Walsh-Hadamard butterfly before compression. The butterfly *spreads* outlier coordinates roughly evenly across all dimensions — flattening the distribution toward Gaussian/Beta.
- After the butterfly, every coordinate looks roughly uniform. A single 8-centroid Lloyd-Max codebook (3-bit indices) is then optimal across all coordinates without per-tile precision routing.
- The result: compressed K and V have *no remaining outliers*. Attention scoring against them at INT8 (Q) × INT3 (compressed K) accumulated in INT24 is quality-neutral on LongBench, Needle-in-Haystack, and similar.

**These two architectures solve different problems.** Your Precision Controller solves "how do I route per-tile precision at run-time when outliers cause INT8 quality to degrade?" Lambda's approach solves "how do I eliminate the outliers entirely at write-time so INT8 always works?"

If TurboQuant works as advertised (and the published evidence — three independent OSS implementations, ICLR'26 acceptance — suggests it does), the per-tile precision gate is unnecessary work: the gate would rarely fire, and when it did the FP16 fallback path is silicon area we paid for but didn't need.

**Specifically for Lambda's MatE:** there is no FP16 multiplier. The systolic array is INT8 × INT4 (for weight matmuls) and INT8 × INT3 (for attention scoring against compressed K). All FP16 work is in VecU (online softmax, RMSNorm, RoPE, SiLU) — the programmable SIMD where FP16 is unavoidable for transcendentals. The MatE fabric never sees an FP16 operand.

**On the accumulator** (a separate but related fix): your spec uses INT16 accumulators in the MAC Array. Lambda's earlier draft did too — and we caught it as a bug on 2026-05-14. INT8 × INT4 produces an 11-bit signed product; reducing K=128 (head_dim) sums needs 18 bits signed, which overflows INT16 (max ±32767) after ~64 accumulations in the worst case. Lambda's MatE now uses an INT16 partial-product register inside each PE plus an **INT24 K-axis accumulator** at the column output. For your MAC Array, the same fix would apply.

---

## What Lambda is absorbing from your framework

**Adopted into Lambda's `arch.yml` (Phase 0 changes, 2026-05-14):**

- **ACU naming.** Lambda's top-level decomposition now groups MatE + VecU + KCE-mini under "ACU" (Attention Compute Unit), mirroring your framework. The internal block IDs stay (HLS continuity), but the umbrella name comes from your work.
- **TIU block.** Real silicon now. Modeled on arXiv 2604.04722 ("Adaptive KV-Cache Quantization for Lightweight On-Device LLMs") — entropy-based per-block precision allocation. Per-block (16-token) 16-bit importance accumulator (256 B SRAM total), updated by VecU during softmax, consumed by MSC (eviction) and KCE-mini (per-block precision). 0.03 mm² total. Your TIU framework gets a concrete on-silicon expression.

**Adopted into Lambda's `src/` (Phase E HLS work, to begin after Phases A/B/C/D):**

- Three-language reference template per block (C++ class / extern "C" / Python golden).
- Bit-accurate verification standard.
- AXI-Lite + AXI-Stream interface convention for any FPGA prototyping step.
- Compiler binding patterns as the entry-point sketch for our toolchain decision.

**Not adopted:**

- Runtime precision controller as an architectural primitive (TurboQuant subsumes the problem).
- FP16 MAC path in MatE (area we don't have at 4 mm²; not needed under TurboQuant).
- Four-block decomposition (ACU/KVCE/TIU/MHC) as a substitute for Lambda's seven-block structure (MatE/VecU/KCE-mini/MSC/LSU/HIF/TIU). Lambda absorbs the *naming convention*, keeps its own block split for HLS reasons.
- Compression-algorithm uncertainty (your KVCE doc lists GEAR/RotateKV/Lexico as candidates). Lambda has decided: TurboQuant. ICLR'26, three OSS implementations, quality-neutral at 3.5 bpe (32-pt) / 4.0 bpe (Lambda's 16-pt). KCE-mini block is locked.

---

## The open question for you

Two reasonable paths forward; both are good.

**Path 1 — Align your work with Lambda's `arch.yml`.** Reshape `adaptive-precision-attention` against Lambda's seven-block decomposition. Your ACU work becomes Lambda's MatE + VecU + KCE-mini (Lambda's `src/blocks/{mate,vecu,kce}/`). Your TIU spec becomes the basis for `src/blocks/tiu/`. Your KVCE/MHC work merges with Lambda's MSC. The Precision Controller doesn't have a Lambda analog (deliberately) — but your ISA + reference-model + verification methodology applies everywhere else. The team gets one canonical chip target.

**Path 2 — Fork your repo as an alternative architecture.** `adaptive-precision-attention` continues as a separate architectural candidate for a different chip target (e.g., a node where FP16 area is cheaper; a workload where outliers don't compress under Hadamard; a teaching artifact). Lambda's repo and yours diverge cleanly. The team has two reference architectures, each pushing its own hypothesis. This is a publishable contrast.

Both are legitimate paths. The choice depends on your preference: do you want the Precision Controller to live as an on-silicon primitive, or as a methodological contribution that lifts up the rest of Lambda's design? Either is a real research first.

We'd love to talk through it. Faculty advisor will schedule a 30-min conversation; you can take this doc into that meeting if it helps.

---

## Where Lambda is locked, and where it isn't (for context)

**Locked:**
- 4 mm² die at TSMC N16FFC via IMEC mini@sic 2.0
- W4 weights / A8 activations / TurboQuant 4.0 bpe KV
- 8×8 MatE INT8×INT4 (no FP16)
- 8-lane VecU FP16/BF16 (transcendentals + online softmax)
- KCE-mini 16-pt Walsh-Hadamard + Lloyd-Max
- MSC PagedAttention 128-entry block table
- LSU 32-instruction in-order RISC
- HIF PCIe Gen3 x1 on M.2 form factor (revised 2026-05-14 from USB-C 2.0)
- TIU per Phase 0.3 (entropy-driven adaptive precision)
- Demo target: 3-5B-class transformer decode at 6-8 tok/s

**Open:**
- Demo model choice: Llama-3.2-3B vs Mistral-NeMo-3B vs Qwen2.5-3B (gated on ML eval Q3 2026)
- LPDDR PHY vendor (Synopsys vs Cadence vs fallback to LPDDR4X) — gated on Q2 2026 quote
- Whether to add sparse-blocked attention as a second add-on (per literature audit, leaning yes)
- Specific microcode encoding for VecU + LSU ISA — drafted in `src/isa/` during Phase E
- FPGA prototyping intermediate step (Zynq UltraScale+) — yes/no TBD

We have room to incorporate your ISA + methodology contributions; we don't have room to add an FP16 MAC fabric or run a runtime precision controller.

---

## Concrete next steps (proposed)

1. **You read this document.** No rush; honest reaction welcome.
2. **30-min conversation with faculty advisor + Lambda lead.** Walk through the two paths above.
3. **Decision (Path 1 vs Path 2) by end of May 2026.**
4. **If Path 1:** we open a shared work plan for porting your ISA + ref-model template onto Lambda's seven-block structure.
5. **If Path 2:** your repo stays autonomous; the methodology contributions (reference template, verification standard, compiler bindings) get cited in Lambda's own `src/` README headers. No merge required.

Either way, your work has shaped Lambda. The ACU naming and the TIU block both come from your framework — they're real on-silicon outcomes of your conceptual contribution.

---

## Companion reads

- Lambda canonical spec: `arch.yml` (file in this repo)
- Lambda iteration history + audit log: `STATUS.md` §2, §4
- Lambda LPDDR PHY tradeoff: `STATUS.md` §5
- Lambda literature audit (frontier attention/FFN survey): `docs/literature_audit.md`
- Lambda visual floorplan: `floorplan.html`
- Lambda dataflow walkthrough: `dataflow_walkthrough.md`

TurboQuant paper for the quantization premise: arXiv 2504.19874 (ICLR'26).
TIU paper: arXiv 2604.04722.
