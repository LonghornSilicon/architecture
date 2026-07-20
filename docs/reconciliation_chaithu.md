# Reconciling `attention-compute-unit` with Lambda's `arch.yml`

**Authors:** Lambda architecture team (Alan Schwartz, UT Austin)
**Audience:** Chaithu Talasila + faculty advisor
**Date:** 2026-05-14
**Status:** open for response

---

> **RESOLUTION (2026-07-18): reversed — MatE adopts the FP16 P·V path.** The conclusion below (that the run-time precision controller / FP16 MAC path was unnecessary work for Lambda) has been **reversed**. MatE is now a heterogeneous INT8 + FP16 systolic array: weight/FFN GEMMs stay W4A8 (INT8×INT4) and Q·K^T stays INT8×(per-channel-dequantized FP16 K), but the **attention P·V matmul routes per-tile INT8 or FP16**, selected by the ACU precision controller (`max(|s|)·N > 10·Σ(|s|)` → FP16, else INT8). The controller + FP16 MAC-array RTL are the Sky130-signed-off `attention-compute-unit` block, adopted verbatim. Note the scope: the per-tile gate applies to **P·V**, *not* to the KV codec or to Q·K^T scoring — ChannelQuant's static per-channel scales + FP16 outlier lane still make a run-time gate unnecessary for the codec and for scoring (those parts of the argument below remain correct). The **accumulator / INT24 discussion below is also unchanged and still correct.** Area/power delta of the FP16 mode is TBD, pending re-synthesis. The reasoning below is preserved for history; read it through this reversal.

---

> **Codec-of-record note:** Lambda's KV codec of record is **ChannelQuant** (per-channel INT4 K grouped G=128 + per-token INT4 V + static top-k k=2 FP16 outlier lane; KV Cache Engine / KVE block; full block RTL complete through Sky130 sign-off in the `kv-cache-engine` repo; recipe follows KIVI, ICML 2024 / KVQuant, 2024). The premise argument below has been migrated to ChannelQuant: outliers are absorbed by per-channel scales + a static FP16 outlier lane (not Hadamard rotation), and keys are dequantized per-channel before scoring (no compressed-domain read path). TurboQuant is cited prior work only; its pure history is on the `legacy/turboquant` branch. The reconciliation *conclusion* (Lambda's static codec vs Chaithu's run-time precision gate) is unchanged.

## What this document is

A peer-to-peer technical reconciliation of `LonghornSilicon/attention-compute-unit` (your work on the Precision Controller + MAC Array + the broader four-block framework: ACU, KV Cache Engine, Token Importance Unit, Memory Hierarchy Controller) against Lambda's current `arch.yml` spec — the canonical chip target for our 4 mm² TSMC 16nm FinFET (N16FFC) tape-out via IMEC mini@sic 2.0. (Lambda's finer taxonomy maps its MSC to the canonical Memory Hierarchy Controller / MHC, and its KVE = your KV Cache Engine block.)

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

> **RESOLUTION (2026-07-18): reversed for P·V.** The decision recorded in this section — that Lambda takes a fully static codec and adds *no* run-time precision gate — has been reversed for the **P·V** matmul. MatE now routes P·V per-tile INT8/FP16 via the ACU precision controller. The static-codec argument still holds for the KV codec and Q·K^T scoring; only the blanket "no run-time gate anywhere in MatE" conclusion is overturned. See the top-of-file note.

Lambda commits to a different quantization premise than your Precision Controller assumes, and that premise drives the rest of the chip's design. Here's the diff:

**Your Precision Controller's premise:** outlier attention tiles need higher precision (FP16) to retain quality; route them dynamically per-tile based on the entropy-equivalent ratio `max(|s|) × N > Σ(|s|) × 10`. The MAC Array has both an INT8 path and an FP16 path; tiles flow to whichever the precision controller selects.

**Lambda's premise (ChannelQuant, codec of record):** outliers are handled **structurally at compress-time** by the codec, not routed per-tile at read-time. Specifically:

- Keys are quantized **per channel** (grouped G=128, D per-channel FP16 scales) to INT4, so each channel's dynamic range is captured by its own scale — a large-magnitude channel does not force the whole tile to a coarse quantizer.
- The **static top-k (k=2) outlier channels**, selected by a calibrated ROM mask, are kept in FP16 verbatim. The largest-magnitude channels — the ones that would otherwise degrade INT4 — never lose precision.
- Values are quantized per token (INT4; INT8 in the CQ-8 tier). Decompression is per-channel `INT4·FP16` (+ FP16 replay for the outlier channels), applied **before** the Q·K^T score matmul.

**These two architectures solve different problems.** Your Precision Controller solves "how do I route per-tile precision at run-time when outliers cause INT8 quality to degrade?" ChannelQuant solves "how do I absorb the outliers into the codec (per-channel scales + a static FP16 outlier lane) so the common path is always low-bit?"

The published ChannelQuant recipe (KIVI, ICML 2024; KVQuant, 2024) and Lambda's measured results — HellaSwag acc_norm within ~0.4–0.8 pt of FP16 at CQ-4+ on Qwen2-0.5B/1.5B — say the per-tile precision *gate* is unnecessary work: the outlier handling is static (a calibrated channel mask), not a run-time gate, and there is no FP16 fallback tile path to pay for. **[RESOLUTION 2026-07-18 — reversed for P·V:** this remains true for the KV *codec* and for Q·K^T scoring, but Lambda has since adopted a run-time per-tile INT8/FP16 gate for the **P·V** matmul. The codec's near-lossless accuracy does not cover P·V, whose precision loss on peaked tiles is a property of the softmax scores, not of the V channels.**]**

**Specifically for Lambda's MatE:** ~~there is no FP16 multiplier.~~ **[RESOLUTION 2026-07-18 — reversed:** MatE *does* have an FP16 MAC path, confined to the per-tile P·V escape.**]** The systolic array is INT8 × INT4 for weight/FFN matmuls; for attention scoring, the KVE dequantizes K per-channel to FP16 *before* the array, so MatE scores Q (INT8) against dequantized K. There is no compressed-domain / raw-index read path. The **P·V** matmul, however, routes per-tile INT8/FP16 via the ACU precision controller (`max(|s|)·N > 10·Σ(|s|)` → FP16). The remaining FP16 work is in VecU (online softmax, RMSNorm, RoPE, SiLU) — the programmable SIMD where FP16 is unavoidable for transcendentals.

**On the accumulator** (a separate but related fix): your spec uses INT16 accumulators in the MAC Array. Lambda's earlier draft did too — and we caught it as a bug on 2026-05-14. INT8 × INT4 produces an 11-bit signed product; reducing K=128 (head_dim) sums needs 18 bits signed, which overflows INT16 (max ±32767) after ~64 accumulations in the worst case. Lambda's MatE now uses an INT16 partial-product register inside each PE plus an **INT24 K-axis accumulator** at the column output. For your MAC Array, the same fix would apply.

---

## What Lambda is absorbing from your framework

**Adopted into Lambda's `arch.yml` (Phase 0 changes, 2026-05-14):**

- **ACU naming.** Lambda's top-level decomposition now groups MatE + VecU + KVE under "ACU" (Attention Compute Unit), mirroring your framework. The internal block IDs stay (HLS continuity), but the umbrella name comes from your work.
- **TIU block.** Real silicon now. Modeled on arXiv 2604.04722 ("Adaptive KV-Cache Quantization for Lightweight On-Device LLMs") — entropy-based per-block precision allocation. Per-block (16-token) 16-bit importance accumulator (256 B SRAM total), updated by VecU during softmax, consumed by MSC (eviction) and the KVE (per-block ChannelQuant tier selection). 0.03 mm² total. Your TIU framework gets a concrete on-silicon expression.

**Adopted into Lambda's `src/` (Phase E HLS work, to begin after Phases A/B/C/D):**

- Three-language reference template per block (C++ class / extern "C" / Python golden).
- Bit-accurate verification standard.
- AXI-Lite + AXI-Stream interface convention for any FPGA prototyping step.
- Compiler binding patterns as the entry-point sketch for our toolchain decision.

**Not adopted:** *(**RESOLUTION 2026-07-18 — the first two bullets below are reversed:** Lambda has adopted both the runtime precision controller and the FP16 MAC path, scoped to the P·V matmul.)*

- ~~Runtime precision controller as an architectural primitive~~ **[reversed — adopted for P·V:** the ACU precision controller now selects INT8/FP16 per P·V tile. ChannelQuant's static per-channel scales + FP16 outlier lane still subsume the *codec* and *scoring* problem, but not P·V.**]**
- ~~FP16 MAC path in MatE~~ **[reversed — adopted for P·V:** MatE now includes an FP16 MAC path used per-tile for P·V; keys are still dequantized to FP16 by the KVE before the array for Q·K^T. Area/power delta TBD, pending re-synthesis.**]**
- Four-block decomposition (ACU/KVE/TIU/MHC) as a substitute for Lambda's seven-block structure (MatE/VecU/KVE/MSC/LSU/HIF/TIU). Lambda absorbs the *naming convention*, keeps its own block split for HLS reasons.
- Compression-algorithm uncertainty (your KVCE doc lists GEAR/RotateKV/Lexico as candidates). Lambda has decided: **ChannelQuant** (recipe following KIVI, ICML 2024 / KVQuant, 2024), ~3.8× at ~4 bits/value, near-lossless at the CQ-4+ tier. The KVE block is the codec of record; TurboQuant is cited prior work only.

---

## The open question for you

Two reasonable paths forward; both are good.

**Path 1 — Align your work with Lambda's `arch.yml`.** Reshape `attention-compute-unit` against Lambda's seven-block decomposition. Your ACU work becomes Lambda's MatE + VecU + KVE (Lambda's `src/blocks/{mate,vecu,kce}/`; the `kce/` dir name is kept for HLS continuity). Your TIU spec becomes the basis for `src/blocks/tiu/`. Your KVCE/MHC work merges with Lambda's MSC. The Precision Controller doesn't have a Lambda analog (deliberately) — but your ISA + reference-model + verification methodology applies everywhere else. The team gets one canonical chip target.

**Path 2 — Fork your repo as an alternative architecture.** `attention-compute-unit` continues as a separate architectural candidate for a different chip target (e.g., a node where FP16 area is cheaper; a workload where outliers don't compress under per-channel quantization; a teaching artifact). Lambda's repo and yours diverge cleanly. The team has two reference architectures, each pushing its own hypothesis. This is a publishable contrast.

Both are legitimate paths. The choice depends on your preference: do you want the Precision Controller to live as an on-silicon primitive, or as a methodological contribution that lifts up the rest of Lambda's design? Either is a real research first.

We'd love to talk through it. Faculty advisor will schedule a 30-min conversation; you can take this doc into that meeting if it helps.

---

## Where Lambda is locked, and where it isn't (for context)

**Locked:**
- 4 mm² die at TSMC 16nm FinFET (N16FFC) via IMEC mini@sic 2.0
- W4 weights / A8 activations / ChannelQuant KV codec (KVE; per-channel INT4 K grouped G=128 + per-token INT4 V + static top-k k=2 FP16 outlier lane)
- 8×8 MatE INT8×INT4 **+ FP16 (P·V)** *(RESOLUTION 2026-07-18 — reversed from "no FP16": weight/FFN GEMMs INT8×INT4, K dequantized per-channel by the KVE before Q·K^T scoring, and P·V routed per-tile INT8/FP16 by the ACU precision controller)*
- 8-lane VecU FP16/BF16 (transcendentals + online softmax)
- KVE ChannelQuant (recipe follows KIVI/KVQuant; block RTL complete through Sky130 sign-off; 16nm PD numbers TBD)
- MSC PagedAttention 128-entry block table (canonical Memory Hierarchy Controller / MHC)
- LSU 32-instruction in-order RISC
- HIF PCIe Gen3 x1 on M.2 form factor (revised 2026-05-14 from USB-C 2.0)
- TIU per Phase 0.3 (entropy-driven adaptive precision)
- Demo target: up to 1.5B-parameter transformer decode (validated on Qwen2-1.5B) at 6-8 tok/s

**Open:**
- Demo model choice within the ≤1.5B target (validated on Qwen2-1.5B) (gated on ML eval Q3 2026)
- LPDDR PHY vendor (Synopsys vs Cadence vs fallback to LPDDR4X) — gated on Q2 2026 quote
- Whether to add sparse-blocked attention as a second add-on (per literature audit, leaning yes)
- Specific microcode encoding for VecU + LSU ISA — drafted in `src/isa/` during Phase E
- FPGA prototyping intermediate step (Zynq UltraScale+) — yes/no TBD

We have room to incorporate your ISA + methodology contributions; ~~we don't have room to add an FP16 MAC fabric or run a runtime precision controller.~~ **[RESOLUTION 2026-07-18 — reversed:** Lambda has found the room: it adopts the runtime precision controller and an FP16 MAC path, scoped to the per-tile P·V matmul. Area/power delta TBD, pending re-synthesis.**]**

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

ChannelQuant recipe basis: KIVI (Liu et al., ICML 2024) / KVQuant (Hooper et al., 2024). TurboQuant (arXiv 2504.19874, ICLR'26) is cited prior work only.
TIU paper: arXiv 2604.04722.
