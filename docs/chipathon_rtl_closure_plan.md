# Chipathon RTL-Closure Plan — Decode Attention Datapath (Sky130)

**Decided 2026-07-21.** Target: the **SSCS Chipathon 2026** shuttle on **GF180MCU**
(GlobalFoundries 180nm, LibreLane multi-macro; template `sscs-chipathon-2026`
`examples/librelane_rtl2gds_gf180/04_counter_alu_multimacro`), ~2–3 months runway.
**PDK locked = GF180MCU.** The
Sky130 sign-offs we already have become **dev-vehicle proofs** (the RTL is physical); the shuttle
re-hardens on GF180. Boundary: the **decode attention datapath** — the coherent completion of the
RTL we have actually built. Projections (QKV/output) and the FFN GEMMs run **off-chip** (host-fed)
for this shuttle; the general 8×8 systolic GEMM/FFN engine is a larger, separate program that can
be added later.

## Repo-of-record split (standing convention, 2026-07-21)

- **Block RTL + block-level verification** live on each block's **own repo**, on its `rtl` branch
  (`kv-cache-engine`, `token-importance-unit`, `attention-compute-unit`, and the cross-block cosim
  in `architecture`). This is where RTL is authored, unit-tested, and committed.
- **PDK work — GF180 LibreLane hardening, multi-macro integration, padring, GDSII, the tapeout
  package** — lives in the **`chipathon-lambda-acu`** repo. It pulls each block's RTL in as a
  hardened macro; it does not author block RTL.

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
| **Q·Kᵀ score row** | **real RTL** (`mate_qkt`) — Phase 1 done 2026-07-21 |
| **softmax / RoPE / RMSNorm** | reference stand-in ← **Phase 2** |

## Phases

| Phase | Build | Cosim effect | Gate |
|---|---|---|---|
| **0** (now) | Plan doc; RTL-maturity honesty in STATUS; finish FP16 wiring (done) | stand-ins labeled | — |
| **1 — MatE Q·Kᵀ** ✅ done | Decode Q·Kᵀ reduction engine (INT8 Q × per-channel FP16 K → L scores); golden from `mac_array_ref`; bit-exact/toleranced TB; swap into cosim BLOCK 1 | scores → **real RTL** ✅ | full cosim `ALL BLOCKS PASS` ✅ (scores rel-err 4e-6) |
| **2 — VecU softmax slice** | Write `vecu.py` golden first (does not exist); then single-row online-softmax + exp LUT + RoPE + RMSNorm; toleranced TB; swap into cosim | probabilities → **real RTL** | full cosim green |
| **3 — Integrate** | ACU top wrapper + mini decode-step control FSM; full-datapath cosim on real Qwen tiles | **stand-ins = 0** | end-to-end green |
| **4 — GF180 hardening** *(in `chipathon-lambda-acu`)* | Harden each block as a GF180 LibreLane macro (start with the already-signed logic blocks to de-risk the port early: precision-controller, mate_pv); then the integrated ACU (KVE SRAM macros, floorplan, hierarchy); 6 sign-off checks | — | clean GF180 sign-off per macro |
| **5 — Padring + submit** *(in `chipathon-lambda-acu`)* | `chip_core.sv` workshop-slot override + serial/SPI loader (≈20 pads ≪ D=128), stitch macros into the chipathon-2026 padring fork, cocotb GL sim, final GDS, MPW submit | — | shuttle-ready package |

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
