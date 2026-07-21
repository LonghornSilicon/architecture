# Chipathon RTL-Closure Plan — Decode Attention Datapath (Sky130)

**Decided 2026-07-21.** Target: an open-source **Sky130** MPW tapeout for the chipathon,
~2–3 months runway. Boundary: the **decode attention datapath** — the coherent completion
of the RTL we have actually built. Projections (QKV/output) and the FFN GEMMs run **off-chip**
(host-fed) for this shuttle; the general 8×8 systolic GEMM/FFN engine is a larger, separate
program that can be added later.

## Why this boundary

"Everything we've built" **is** the attention + KV datapath (KVE, TIU, precision-controller,
P·V). The projection/FFN GEMMs were *never* RTL — they are part of the un-built 8×8 systolic
array, spec-only from day one. So closing "our" gap = finishing the attention pass on-die.
The ACU (Attention Compute Unit) is only meaningfully "attention" once MatE does Q·Kᵀ scoring
and VecU does softmax; those are the two blocks we build here.

## The key feasibility lever: decode ⇒ matrix-**vector**

The validated workload is Qwen2 **decode** (one query token per step). That collapses the
hard 2D structures into 1D:
- **Q·Kᵀ** = one Q vector (D) · L cached K vectors → L scores. A **reduction engine**, not a
  full weight-stationary 2D systolic array. K arrives per-channel-dequantized FP16 from the
  KVE, so it reuses the existing FP16 datapath (INT8 Q → exact fp16, ×fp16 K, fp32 accumulate).
- **softmax** = one row → the running-max/running-sum recurrence, single-lane. Not the full
  8-lane programmable microcode VecU — just the decode softmax slice + the 64-entry exp LUT.
- **P·V** = already `mate_pv` (INT8) + `mate_pv_fp16` (FP16 escape).

## Closure harness: the cosim is the scoreboard

`architecture/rtl/tb/tb_chip_cosim.sv` runs green today with **reference stand-ins** for the
un-built stages (scores supplied as data; probabilities precomputed). We replace each stand-in
with **verified RTL one at a time, keeping the cosim green throughout** (bit-exact / toleranced
to the same golden). Closure metric = **# reference stand-ins → 0**. When it hits zero, the same
green cosim *is* a full-attention-datapath RTL sim on real Qwen tensors — that is the honest
"reliably tested end-to-end on 130nm."

Current cosim (post FP16 wiring, commit `2aaa471`):

| Cosim stage | Status |
|---|---|
| BLOCK 2 (KVE) reconstruct V̂ | **real RTL** |
| BLOCK 2b/2c (MatE P·V, INT8 + FP16 escape) | **real RTL** |
| BLOCK 3 (TIU) keep-tier + evict | **real RTL** |
| BLOCK 1 (ACU) precision gate | **real RTL** |
| **Q·Kᵀ score row** | reference stand-in ← **Phase 1** |
| **softmax / RoPE / RMSNorm** | reference stand-in ← **Phase 2** |

## Phases

| Phase | Build | Cosim effect | Gate |
|---|---|---|---|
| **0** (now) | Plan doc; RTL-maturity honesty in STATUS; finish FP16 wiring (done) | stand-ins labeled | — |
| **1 — MatE Q·Kᵀ** | Decode Q·Kᵀ reduction engine (INT8 Q × per-channel FP16 K → L scores); golden from `mac_array_ref`; bit-exact/toleranced TB; swap into cosim BLOCK 1 | scores → **real RTL** | full cosim `ALL BLOCKS PASS` |
| **2 — VecU softmax slice** | Write `vecu.py` golden first (does not exist); then single-row online-softmax + exp LUT + RoPE + RMSNorm; toleranced TB; swap into cosim | probabilities → **real RTL** | full cosim green |
| **3 — Integrate** | ACU top wrapper + mini decode-step control FSM; full-datapath cosim on real Qwen tiles | **stand-ins = 0** | end-to-end green |
| **4 — Sky130 GDSII** | Harden integrated ACU (KVE SRAM macros, floorplan, hierarchy); 6 sign-off checks at top | — | clean sign-off |
| **5 — Tapeout harness** | Efabless/Caravel (or OpenFrame) integration, IO ring, final GDS, MPW submit | — | shuttle-ready |

## Risk register (honest)

- **VecU is the long pole** — no golden model exists yet (write `vecu.py` before RTL); the
  transcendental LUTs + rescale are fiddly.
- **Top-level Sky130 close** — the integrated datapath is far larger than the individual tiles;
  the KVE SRAM macros make floorplanning real.
- **2–3 months is tight but plausible** *with the decode simplification + parallel agents*. It is
  **not** plausible for the full systolic GEMM + FFN engine — which is exactly why those are
  off-chip for this shuttle.

## Verification discipline

Every new block: golden-first, bit-exact (INT) or toleranced (`rel_err < 5e-3`, FP) TB, **then**
swap into the cosim and re-run the *full* regression — no phase advances on a red cosim.
