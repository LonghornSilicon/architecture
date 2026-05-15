# Lambda — Handoff for the Next Session

**Snapshot date:** 2026-05-14 (end of session)
**For:** Alan Schwartz returning, or any teammate picking up the work fresh.
**Reading time:** 10 minutes top-to-bottom to be fully oriented.

If you read only one thing, read §0. If you read two, add §3 (the TODO).

---

## 0. The 60-second version

**Lambda** is a **4 mm² standalone transformer-decode ASIC** on **TSMC N16FFC**, designed for tape-out via the **IMEC / Europractice mini@sic 2.0** academic shuttle (~\$60–100K shuttle, ~\$170–290K total chip cost). It runs **3–5 B-parameter W4A8 LLMs** at **6–8 tok/s decode in 2.6 W typical**, with three architectural firsts: silicon TurboQuant KV compression, compressed-domain attention scoring (INT8 × INT3), and a Token Importance Unit (TIU) driving adaptive-precision KV.

**Where we are:** spec is bit-fixed and audited (8 bugs corrected before HLS); repo is restructured to single canonical target; Phase 0 mid-stream arch updates (PCIe Gen3 x1 HIF, ACU naming, TIU block, area accounting fix) are in; a seminal paper exists in `paper/lambda.{tex,pdf}`. All committed.

**What comes next:** decide LPDDR5X vs LPDDR4X based on Q2 2026 vendor quote; finish the open spec items in §3; then Phase A/B/C research dives; then Phase E HLS implementation. Plan file: `~/.claude/plans/proud-yawning-hopcroft.md`.

---

## 1. State of the chip in one paragraph

Lambda integrates **seven on-die functional blocks** under five top-level units (**ACU / MSC / LSU / TIU / HIF**). The ACU groups MatE (8×8 INT8×INT4 systolic with INT24 K-axis accumulator), VecU (8-lane FP16/BF16 SIMD running FA-3 online-softmax + RoPE + RMSNorm + SiLU microcode), and KCE-mini (16-pt Walsh-Hadamard + Lloyd-Max codebook + bit-pack at 4.0 bpe / 4× compression vs FP16). MSC provides PagedAttention via a 128-entry block table, a 4-port SRAM crossbar, and the LPDDR5X x16 protocol-side controller. LSU is a tiny 32-instruction in-order RISC walking the pre-compiled per-layer schedule from 4 KB of microcode RAM. **TIU (new this session)** is a 0.03 mm² block that accumulates per-block attention entropy and drives both heavy-hitter eviction (to MSC) and per-block adaptive precision (to KCE-mini). HIF is a PCIe Gen3 x1 endpoint on the M.2 2280 carrier-card form factor. On-die SRAM is 0.8 MB across 4 banks (kv_scratchpad 0.4 + activation_buf 0.3 + weight_stream 0.05 + codebook ROM 64 KB). Off-die is a 4–8 GB LPDDR5X-8533 x16 package and a host laptop / dev board over PCIe.

**Targets at decode (LPDDR5X x16 baseline):** Llama-3.2-3B @ 7.4 tok/s, Mistral-NeMo-3B @ 8.0, Qwen2.5-3B @ 7.7, Phi-3.5-mini @ 6.3, Llama-3.2-1B @ 19.3. **Power:** 2.6 W typical / 3.3 W peak. **Area:** 4.354 mm² gross / **4.014 mm² with recommended shrink path** (contingent on PHY vendor quote landing at 1.0 mm² best case).

---

## 2. What was decided in this (2026-05-14) session

The session covered three distinct phases of work. The full audit trail is in [`../STATUS.md`](../STATUS.md) §2–§4. Brief version:

**(a) Pre-RTL audit + 8 bug fixes.** Pre-tape-out audit of every load-bearing number in the spec caught and corrected 8 inconsistencies — see [`../STATUS.md`](../STATUS.md) §4 for the per-bug list. None changed any architectural decision; every fix was either a math error (KV bytes/token off by 2.3×, MatE INT16 accumulator would saturate at K>64, 3-5× headroom was a derivation error) or a stale claim from an earlier iteration (Qwen 32K on-die, comfortable headroom at PHY=1.0 mm²). The audit log is preserved as `# Earlier drafts claimed X` comments throughout [`../arch.yml`](../arch.yml) for traceability.

**(b) Repo restructure to single canonical target.** Retired Lambda v1 (KV coprocessor) and Lambda v3 (all-SRAM tiny-LLM) candidates; promoted v2 to be the chip target with no version suffix. Deleted `archs/`, `archs/_shared/`, `archs/lasso/`, `PRDs/`, `scripts/v2_design_space/`, `roadmap.md`, `archs.yaml`. Promoted `Lambda_v2_4mm2.yaml` → `arch.yml` at root, etc. Repo went from 32 files to 17 + the new `docs/` and `src/` trees.

**(c) Phase 0 mid-stream arch updates.** Four mid-stream changes triggered by user direction:
   - **HIF: USB-C 2.0 → PCIe Gen3 x1** on **M.2 2280** form factor. +0.25 mm² area; weight-load time 25 s → 1.5 s; vendor IP has public 16nm datasheets.
   - **ACU naming convention adopted** (umbrella for MatE + VecU + KCE-mini); honors Chaithu Talasila's `adaptive-precision-attention` framework while preserving Lambda's block decomposition.
   - **TIU block added** (NEW, 0.03 mm²) — modeled on arXiv 2604.04722 "Adaptive KV-Cache Quantization for Lightweight On-Device LLMs."
   - **Area accounting fix** — earlier drafts silently dropped the routing_overhead_buffer from `total_mm2`; gross area is now honestly 4.354 mm², shrink path lands at 4.014 mm².

**(d) Seminal paper.** Wrote [`../paper/lambda.tex`](../paper/lambda.tex) (8 pages, IEEEtran double-column conference format) synthesizing the work. Three TikZ figures (top-level architecture, area accounting, performance curve), two tables (per-block area, comparison vs Apple ANE / Hexagon / academic FPGA). Bibliography has 36 real citations covering KV compression, online attention, paged management, quantization, transformer primitives, speculative decoding, reference platforms, demo target model cards, compiler/PD tools, and the Etched IP-clearance reference. Build: `cd paper && make` (auto-detects `tectonic` or `pdflatex`).

**Commits this session:**
- `8de5298` — Pre-RTL audit, repo cleanup, Phase 0 arch updates (PCIe HIF + ACU + TIU)
- `accda30` — Add seminal paper: IEEEtran LaTeX source + comprehensive bibliography + PDF

---

## 3. TODO list — what to do next, in priority order

These are the open items from the end of session. Numbered for reference; sub-items are the specific spec gaps caught in the audit.

### 3.1 — Top-priority decision (gates everything else)

**(1) LPDDR4X pivot decision.** My recommendation from the end of the session was to flip primary/fallback: **make LPDDR4X x16 the primary path, LPDDR5X x16 the future v2.0 stretch**. Rationale (full version in [`../STATUS.md`](../STATUS.md) §5):
   - Public Cadence/Synopsys 16nm datasheets vs LPDDR5X's NDA-only references → first-FinFET-PHY risk (R-Lv2-01) drops from critical to medium.
   - 0.2 mm² area freed; use it for either 1.0 MB SRAM, or 12×12 MatE (180 GOPS) for hardware speculative decoding, or keep activation buffer at 0.3 MB.
   - Model class: 4.8 B → 2.4 B at 5 tok/s threshold. Lose Llama-3.2-3B / Mistral-NeMo-3B / Qwen2.5-3B as comfortable targets; **gain** Llama-3.2-1B @ 9.6 tok/s, Qwen2.5-1.5B @ 8, SmolLM2-1.7B @ 7, Gemma-2-2B @ 6.
   - Reframes the headline thesis: "first open-source academic standalone 1–2 B-class accelerator at 16nm with public-datasheet PHY IP" — still a publishable first.
   - **If you decide LPDDR4X main:** cascade through `arch.yml`, `floorplan.html`, `paper/lambda.tex` §VI, and the area accounting math. ~2–3 hours of focused edits.

### 3.2 — Numerical and structural sanity checks

**(2) INT24 K-axis accumulator numerical eval.** Sanity-check INT24 holds at the worst-case FFN K-dimension (Llama-3 SwiGLU intermediate K = 8192). Math: log₂(8192) + 11 = 24 bits exactly. **INT24 *just* fits — verify there's no off-by-one or signed-vs-unsigned corner case.** Run a Python sweep on Llama-3.2-3B's actual per-layer dimensions and confirm no saturation. May want to bump to INT28 or INT32 for safety margin; INT24 is the *minimum* not necessarily the *right* answer. Spec source: [`../arch.yml`](../arch.yml) MatE block, `accumulator_rationale` field.

**(3) Per-block optimization tests — well-defined success criteria.** Currently `src/blocks/<block>/README.md` has the spec but no measurable acceptance criteria. Each of the seven blocks (MatE, VecU, KCE-mini, MSC, LSU, HIF, TIU) needs: target metric (cycles per op / GOPS / mm² / mW), test-vector source, pass/fail threshold, golden-model reference. Land this in each block README before HLS begins. Template suggestion: a "verification gates" subsection per block.

### 3.3 — Open spec items (from end-of-session attention-mechanism audit)

These are spec gaps that need to close before the HLS work (Phase E) can start cleanly. Each maps to a specific block in [`../src/blocks/`](../src/blocks/).

   **(4) Sparse-blocked attention** — announced as a CSR mode in MSC (`attention_pattern_modes: dense_paged | sliding_window | sparse_blocked | local_plus_global_hybrid`), but the **mask templates**, the **per-layer config bit format**, and the **MatE iteration order** under sparse-blocked aren't fully spec'd yet. Lands in [`../arch.yml`](../arch.yml) MSC subsection and [`../src/blocks/msc/README.md`](../src/blocks/msc/README.md). Reference: Longformer (arXiv 2004.05150), BigBird (arXiv 2007.14062), Gemma-2 local+global hybrid.

   **(5) TIU ⟷ sparse-blocked interaction** — they pair conceptually (TIU drives "which blocks matter", sparse-blocked drives "which positions to attend to"), but the joint behavior under both modes simultaneously isn't documented. **Decide: do they compose, or are they mutually exclusive CSR modes?** Reference: [`../src/blocks/tiu/README.md`](../src/blocks/tiu/README.md) §"Open design questions" item 4.

   **(6) Asymmetric K3/V2 mode bit-pack** — [`../arch.yml`](../arch.yml) has it as a CSR mode at 3.5 bpe average / 4.57× compression, but the actual **K-half vs V-half pack format** isn't spelled out yet. Need to confirm K-half kv_scratchpad and V-half kv_scratchpad layout. May require splitting the 0.4 MB kv_scratchpad bank into a 0.27 MB K-half + 0.13 MB V-half, or maintaining a unified bank with per-token tag bits. Reference: TurboQuant paper §5 (asymmetric production mode).

   **(7) FP4 codebook mode (NVFP4 levels)** — alt 64-byte ROM contents specified abstractly; the **E2M1 round-to-nearest map** (especially around the irregular {0, 0.5, 1, 1.5, 2, 3, 4, 6} levels) needs an explicit comparator network spec. The classifier needs to handle non-uniform spacing. Reference: NVFP4 spec, OCP MX spec.

   **(8) FA-3 microcode listing** — high-level algorithm described in [`../arch.yml`](../arch.yml) VecU block and [`../dataflow_walkthrough.md`](../dataflow_walkthrough.md) Stage 9; **concrete microcode opcodes + register allocation for VecU isn't drafted.** Phase E work proper; first concrete artifact in [`../src/isa/vecu_microcode.h`](../src/isa/) and `../src/blocks/vecu/golden/vecu.py`. Reference: FlashAttention-3 paper (arXiv 2407.08608).

   **(9) Compressed-domain attention numerical eval** — **this is the chip's biggest novel claim.** INT8 (Q) × INT3 (compressed K) → INT24 reduction is mathematically sound, but needs **MMLU / LongBench / Needle-in-a-Haystack eval against Llama-3.2-3B + TurboQuant 4.0 bpe** to confirm the FP16-free claim holds at our 16-point Hadamard (the published TurboQuant result is for 32-point Hadamard at 3.5 bpe — we're at 16-pt at 4.0 bpe). Owner: ML student. Deadline target: 2026-07. Gates the demo-model decision.

   **(10) MLA-gap revisit decision** — currently locked out per [`../docs/literature_audit.md`](literature_audit.md) §3. **If DeepSeek-V2-style models become the dominant 3–5 B target by tape-out 2028, this gap is the chip's biggest competitive risk.** Worth a periodic check (every 3–6 months). The architectural cost to add MLA is real: MSC + MatE redesign for latent KV layout, ~+0.05 mm² across blocks, ~30 verification tests.

   **(11) Etched-patent IP review** — defensive review with **UT Austin tech transfer office** still pending. Mentioned in [`../paper/lambda.tex`](../paper/lambda.tex) §VII.B and [`../arch.yml`](../arch.yml) MatE block note. Not blocking, but should clear before silicon commit. Patent reference: US 2024/0419516 A1 (Etched.ai).

---

## 4. Decisions LOCKED — do not unwind without thought

These are committed architectural decisions. If you find yourself wanting to change one, the bar is high — there is real reasoning behind each that's been audited.

| Decision | Lives in | Why it's locked |
|---|---|---|
| 4 mm² die at TSMC N16FFC | `arch.yml` `metadata` + `process` | IMEC mini@sic 2.0 minimum-block-area tier; ~\$60–100K academic shuttle. Anything bigger is unfundable. |
| W4A8 quantization | `arch.yml` `quantization_strategy` | ACL'25 sweet spot for small LLMs; AWQ + GPTQ + SmoothQuant trio is production-grade. |
| TurboQuant 4.0 bpe at 16-pt Hadamard (KCE-mini) | `arch.yml` KCE-mini block | First-principles derivation: 16×3 + 16 = 64 bits / 16 elem = 4.0 bpe → 4× vs FP16. Earlier 3.5/5.3 bpe claims were errors. |
| 8×8 MatE INT8×INT4 (64 PEs, 128 GOPS peak) | `arch.yml` MatE block | Bandwidth-bound regime needs only 48 GOPS sustained; 8×8 gives 1.6× headroom (constant across model size). |
| **INT24 K-axis accumulator** (NOT INT16) | `arch.yml` MatE block | INT16 saturates at K>64 for INT8×INT4 reductions; INT24 is the minimum safe width. |
| **Compressed-domain attention scoring** (INT8 × INT3 direct) | `arch.yml` `attention_compute` | TurboQuant's Hadamard rotation eliminates outliers → no FP16 fallback needed → saves ~0.4 mm² of MatE fabric. Novel contribution. |
| **PCIe Gen3 x1 HIF on M.2 2280** | `arch.yml` HIF block, [`../src/blocks/hif/README.md`](../src/blocks/hif/README.md) | Decided 2026-05-14 (was USB-C 2.0). 1.5 s weight load vs 25 s; vendor IP has public 16nm datasheets; M.2 form factor enables plug-and-play. |
| **ACU naming convention** (umbrella = MatE+VecU+KCE) | `arch.yml` `compute_unit_grouping` | Honors Chaithu's framework; preserves internal block structure for HLS. |
| **TIU block** (per-block attention-entropy accumulator) | `arch.yml` TIU block, [`../src/blocks/tiu/README.md`](../src/blocks/tiu/README.md) | NEW 2026-05-14. First silicon implementation of arXiv 2604.04722. 0.03 mm² for real H2O / Scissorhands / adaptive-precision KV claim. |
| Single LPDDR5X x16 channel (or LPDDR4X x16 fallback) | `arch.yml` `memory_hierarchy` | LPDDR5X x32 / x64 don't fit at 4 mm². The choice is x16 + which generation. |
| Single-session chip (no continuous batching, no Tier-3 eviction) | `arch.yml` MSC block | 4 mm² has no room for multi-session state. Deliberate scope cut. |
| LSU 32-inst in-order RISC, single-issue | `arch.yml` LSU block | Transformer decode is structurally identical layer-to-layer; static schedule walked deterministically suffices. |
| Programmable VecU (NOT fixed-function softmax/RoPE/GELU) | `arch.yml` VecU block | Verification surface argument: one programmable block < four fixed-function blocks. Speed gain from fixed-function is <2% (decode is bandwidth-bound, not VecU-bound). Conclusion from end-of-session discussion. |

---

## 5. Decisions OPEN — gated on data or future deliberation

| Open decision | Gated on | Expected resolution |
|---|---|---|
| LPDDR5X vs LPDDR4X PHY | Q2 2026 vendor quote (Synopsys + Cadence parallel) | 2026-06 |
| Demo target model (Llama-3.2-3B / Mistral-NeMo-3B / Qwen2.5-3B) | ML student quality eval (MMLU + LongBench) at W4A8 + TurboQuant 4.0 bpe | 2026-07 |
| Senior FinFET PHY PD engineer in place | Hiring / partnership conversation | 2026-07 |
| IMEC mini@sic 2.0 4 mm² N16FFC pricing | Direct quote via `eptsmc@imec.be` | 2026-05 |
| Sparse-blocked attention add-on detail | Phase B literature audit completion | 2026-06 |
| MLA support for future revision | Periodic 3–6 month check on 3–5 B model trends | ongoing |
| Chaithu's reconciliation response (align with Lambda, or fork) | Faculty advisor conversation using `reconciliation_chaithu.md` | 2026-05 |
| FPGA prototyping intermediate step (Zynq UltraScale+) | Team capacity decision | 2026-08 |

---

## 6. Where everything lives

```
architecture/
├── README.md                       ← entry point; what Lambda is + repo guide
├── STATUS.md                       ← live journal: iteration history, audit log,
│                                     LPDDR PHY tradeoff, open questions
├── arch.yml                        ← THE canonical machine-readable spec
│                                     (every number; every CSR mode; every risk)
├── floorplan.html                  ← visual: die floorplan + area + workload
│                                     coverage + KV capacity tables
├── dataflow_walkthrough.md         ← teaching doc: one decode token through every
│                                     block, stage by stage
│
├── docs/
│   ├── handoff.md                  ← THIS DOCUMENT
│   ├── literature_audit.md         ← every attention / FFN / KV mechanism with
│   │                                 go/no-go decision + citations
│   └── reconciliation_chaithu.md   ← shareable critique of teammate's
│                                     adaptive-precision-attention work
│
├── paper/
│   ├── lambda.tex                  ← IEEEtran conference paper (8 pages)
│   ├── lambda.bib                  ← 36 real citations
│   ├── lambda.pdf                  ← pre-compiled output
│   ├── Makefile                    ← `make` auto-detects tectonic or pdflatex
│   └── README.md                   ← build + target venue notes
│
└── src/                            ← HLS implementation scaffolding
    ├── README.md                   ← build order: MatE PE → KCE → VecU →
    │                                 TIU → MSC → LSU → HIF
    ├── isa/                        ← LSU + VecU microcode + CSR map headers
    ├── golden/                     ← Python bit-accurate reference per block
    └── blocks/
        ├── mate/    vecu/    kce/  ← ACU compute fabric
        ├── msc/     lsu/           ← memory + control
        ├── tiu/                    ← NEW: token importance unit
        └── hif/                    ← PCIe Gen3 x1
```

**Canonical sources by question type:**

| Question | Canonical source |
|---|---|
| What's the area of block X? | `arch.yml` `area_summary_mm2` AND `top_level.area_accounting_mm2` |
| What's the bpe / compression rate? | `arch.yml` KCE block (4.0 bpe canonical) |
| What's the power budget? | `arch.yml` `performance_targets.power_budget` |
| How does decode flow through the chip? | `dataflow_walkthrough.md` |
| What does each CSR mode do? | `arch.yml` per-block `csr_modes` |
| What attention mechanism do we support? | `docs/literature_audit.md` decision table |
| Why did we pick X over Y? | `STATUS.md` (history) or `arch.yml` `*_rationale` fields |
| What changed in the last audit? | `STATUS.md` change log + `arch.yml` `# Earlier drafts claimed X` comments |
| What's risky? | `arch.yml` `risks` + `STATUS.md` §8 |
| Next concrete action? | `STATUS.md` §6 OR §3 of this document |

**The plan file** (Phase A/B/C/D/E deep-dive plan) lives at `~/.claude/plans/proud-yawning-hopcroft.md` — outside the repo so it doesn't sync across machines unless you explicitly copy it.

---

## 7. Risks in priority order

The single load-bearing chip-level risk: **LPDDR PHY at 16nm** (R-Lv2-01, R-Lv2-03 in [`../arch.yml`](../arch.yml) `risks`).

1. **LPDDR5X x16 PHY at 16nm** — NDA-only references, ±0.3 mm² real swing, first-FinFET-PHY for the team. Vendor quote is the load-bearing data point. **Mitigation:** LPDDR4X x16 fallback path documented in [`../STATUS.md`](../STATUS.md) §5; senior PHY engineer hire/partnership required for LPDDR5X path.
2. **IMEC mini@sic 2.0 pricing for 4 mm² N16FFC** — non-public; \$60–100K is an academic-discount-tier estimate. Direct quote needed; affects funding plan.
3. **W4 quantization quality on 3–5 B class** — literature says 3–6% MMLU degradation acceptable for demo; needs eval on the specific demo target model.
4. **INT24 sufficiency at K=8192 FFN dimension** — log₂(K) + 11 = 24 bits exactly; *just* fits. Sanity-check before HLS (TODO §3.2 item 2).
5. **Compressed-domain attention quality** — the chip's headline claim. TurboQuant's 32-pt result needs to hold at our 16-pt variant; eval needed (TODO §3.3 item 9).
6. **Etched patent (US 2024/0419516 A1)** — defensive review with UT tech transfer pending. Not blocking; architectural read is non-infringement (one fabric, two modes, not two structurally separated circuits).
7. **Tape-out timeline (2028)** — model class may commoditize on mobile NPUs by then; mitigation is the open-source-academic-standalone differentiation, which doesn't compete on raw perf.

---

## 8. The deep-dive plan (Phases A/B/C/D/E)

Per the approved plan at `~/.claude/plans/proud-yawning-hopcroft.md`. Research-first sequencing, implementation after. Estimated 3–5 weeks of focused work to clear Phases A/B/C/D; then Phase E (HLS) is months.

| Phase | What | Output |
|---|---|---|
| **A. Chaithu reconciliation** | Re-read his 4 docs; map his blocks to ours; absorb naming + methodology, reject the FP16 MAC path | [`../docs/reconciliation_chaithu.md`](reconciliation_chaithu.md) (already drafted) + a faculty conversation |
| **B. Attention/FFN deep dive** | Read FA-3, MLA, PagedAttention, GQA, KV survey, KVQuant, TurboQuant, FlashInfer, TIU paper carefully; populate the literature audit | [`../docs/literature_audit.md`](literature_audit.md) sections filled in (10 done, 10 stubs) + the 8 open spec items in §3.3 closed |
| **C. Etched patent** | Focused reading + UT tech transfer conversation | Defensive non-infringement note in [`../arch.yml`](../arch.yml) + clearance |
| **D. arch.yml v0.4 consolidation** | Apply A+B+C outputs as a single coherent revision; re-validate; bump version metadata | [`../arch.yml`](../arch.yml) v0.4 + change-log entry in [`../STATUS.md`](../STATUS.md) |
| **E. HLS implementation** | Stratus C++ + Python golden per block; MatE PE first (long pole), then KCE, then TIU + VecU, then MSC + LSU + HIF | All `src/blocks/*/{<block>.h,<block>.cpp,golden/,tb/,stratus.tcl}` populated; bit-exact verification |

---

## 9. Quick command reference

```bash
# Build the paper
cd paper && make                                       # auto-detects tectonic/pdflatex
make view                                              # open the PDF
make clean                                             # delete intermediates

# Validate the spec
python3 -c "import yaml; yaml.safe_load(open('arch.yml'))"

# Visual floorplan
open floorplan.html

# Status + plan
cat STATUS.md | head -50                               # state snapshot
cat docs/handoff.md                                    # this doc
cat ~/.claude/plans/proud-yawning-hopcroft.md          # full deep-dive plan

# Git
git log --oneline -5                                   # recent commits
git status

# Useful greps
grep -n "id: " arch.yml | head -20                     # all block IDs
grep -rn "TODO\|TBD\|XXX" arch.yml src/                # open items in code
```

---

## 10. Reading order for someone new

For Alan returning fresh: §0 of this doc + the last `git log` entry should be enough.

For a teammate seeing the project for the first time:

1. **60 seconds:** §0 of this doc
2. **5 min:** [`../README.md`](../README.md) + [`../STATUS.md`](../STATUS.md) §1
3. **15 min:** [`../paper/lambda.pdf`](../paper/lambda.pdf) (the paper is the most concentrated synthesis)
4. **30 min:** [`../dataflow_walkthrough.md`](../dataflow_walkthrough.md) for the concrete-token mental model + [`literature_audit.md`](literature_audit.md) for the design-space context
5. **Reference depth:** [`../arch.yml`](../arch.yml) (every number) + [`../floorplan.html`](../floorplan.html) (visual)
6. **Implementation depth:** [`../src/`](../src/) per-block READMEs

---

## 11. Ownership + contacts

| Role | Person / channel |
|---|---|
| Architecture lead, RTL lead | Alan Schwartz, UT Austin (`aschwartz0408@utexas.edu`) |
| Faculty advisor | TBD (UT Austin computer architecture lab) |
| Companion ISA work | Chaithu Talasila — `github.com/LonghornSilicon/adaptive-precision-attention`; reconciliation status in [`reconciliation_chaithu.md`](reconciliation_chaithu.md) |
| Shuttle program | IMEC / Europractice — `eptsmc@imec.be` |
| PHY vendor IP | Synopsys DesignWare (LPDDR + PCIe) OR Cadence Denali (LPDDR) + Cadence PCIe Gen3 PHY |
| EDA flow | Cadence end-to-end: Stratus HLS, Genus, Innovus, Calibre, PrimeTime |

---

## 12. One final note

Every load-bearing number in the spec has been audited at least once. Every architectural commitment has explicit reasoning in either the `arch.yml` rationale fields or the STATUS.md change log. Every external claim has a real citation. The repo is in a state where **someone new can pick up the work** by reading this document + STATUS.md + the paper — about 25 minutes total — and resume.

**The most prudent next move:** before any HLS code lands, decide LPDDR4X-vs-LPDDR5X (TODO §3.1) and close the 8 open spec items in §3.3. Phase E HLS work assumes the architecture is frozen; closing these items is what freezes it.

Good luck. The chip is in good shape.

— end of handoff —
