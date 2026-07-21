# MatE — Matrix Engine (8×8 INT8×INT4 + FP16 (P·V) systolic)

**Spec source:** `../../../arch.yml` block `matrix_engine` (lines look for `id: matrix_engine`).

## What this block is

- 8×8 grid = 64 heterogeneous INT8 + FP16 PEs at 1 GHz → 128 GOPS peak, 76.8 GOPS sustained at 60% util. *(16nm ESTIMATE: peak = 64 PE × 2 ops × 1 GHz target clock; sustained = 128 × 0.60 — arch.yml `matrix_engine`; analytical, not silicon.)* The array is **INT8×INT4 for weight/FFN GEMMs**, with an **FP16 MAC path used per-tile for the P·V matmul** (see below). *(Area/power delta of the FP16 mode is TBD, pending re-synthesis.)*
- Weight-stationary primary dataflow (Q/K/V proj, FFN, logits) — always INT8×INT4
- Output-stationary alt dataflow for Q·K^T (Q pinned, K streams from kv_scratchpad)
- Q·K^T scoring on **per-channel-dequantized K**: under the ChannelQuant codec of record the KVE reconstructs K as `INT4_code · FP16_scale` (+ FP16 replay for the k=2 outlier channels) **before** the score matmul — there is no compressed-domain / raw-index read path. Q·K^T stays INT8×(dequantized FP16 K).
- **Per-tile INT8/FP16 P·V matmul.** The attention P·V product routes each tile to the INT8 path or the FP16 MAC path, selected by the **ACU precision controller** (`max(|s|)·N > 10·Σ(|s|)` → FP16, else INT8; peaked-attention tiles escalate to FP16). The controller + FP16 MAC-array RTL are the Sky130-signed-off `attention-compute-unit` block.
- **INT16 partial-product register inside each PE.** Two accumulator widths at the column output, because the two integer reduction axes differ in length: **INT24 for hidden-dim reductions** (W4A8 GEMM, Q·Kᵀ — product 10-bit × ≤4096 terms = 22b) and **INT32 for the INT8 P·V path** (reduces over the *token* dim, so width scales with context: a flat causal row of length L needs 14+ceil(log2 L) bits — INT24 only guarantees no overflow to ~520 tokens, INT32 to ~133k). FP32 for FP16 tiles. Re-derived 2026-07-20 on Qwen2-1.5B (`attention-compute-unit/analysis/pv_accumulator_width.py`): empirically the P·V accumulator stays at ~2^21 (21b) and does **not** grow with context — real softmax is peaky — so INT24 works in practice, but INT32 is specced for guaranteed correctness on any distribution. (Earlier "INT16 accumulator" was a spec bug — `STATUS.md` §4 #3.)
- 0.10 mm² target at 16nm; 0.32 W at 50% util — **16nm ESTIMATE** (arch.yml `what_fits`: 64 PE × ~600 µm²/PE + aux buffers ≈ 0.10–0.16 mm²; power = 5 W/TOPS × 0.128 × 0.5). Analytical planning figure, not silicon; the only signed-off RTL is the 130nm Sky130 proxy (`mate_pv`) in the attention-compute-unit repo.

## Quick start

```bash
# From the chamber, after sync-promote + tools/install.sh (one-time):
lambda-stratus mate gui              # open Stratus IDE on the block's project.tcl
lambda-stratus mate batch BASIC      # headless cynth BASIC
lambda-stratus mate diagnose         # check project.tcl + module availability
```

See [`../../../docs/tools-overview.md`](../../../docs/tools-overview.md) for the full chamber tooling framework.

## Files

- `mate.h` — top-level entity, Stratus-synthesizable
- `mate.cpp` — implementation
- `pe.h` / `pe.cpp` — single PE (gets replicated 64× by the systolic generator)
- `tb/` — C++ testbench (peer of `stratus/`); exercises both dataflow modes
  - `main.cpp` — sc_main entry
  - `system.h` / `system.cpp` — SC_MODULE testbench top
  - `data/` — test vectors
- `stratus/` — Stratus HLS project
  - `project.tcl` — define_hls_module + sources + targets (clock 1 GHz, target Cadence N16FFC stdcell)
  - `hls.tcl` — HLS configs and cynth invocations (when multi-config exploration needed)
  - `memgen.tcl` — memory generator config (when any RAMs used)

Build output lands under `$LAMBDA_WORK/mate/stratus/<run-id>/<config>/` (= `~/work/lambda/mate/stratus/<UTC-runid>/<config>/` by default — v0.4.1 per-invocation isolation; **outside** the git mirror so `sync-promote`'s `git reset --hard` can never touch it). On batch success, Stratus's emitted `<run-id>/<config>/mate.v` is also republished to `$LAMBDA_WORK/mate/release/mate.hls.v` (the cross-stage contract path read by Genus). A STATUS file at `<run-id>/STATUS` records PASS\|FAIL + UTC + rc. See `docs/tools-overview.md` "Filesystem & run-area" and "Directory dependencies and log/run dataflow".

## Open design questions for the team

1. Output-stationary mode CSR — is the per-tile mode switch fast enough to interleave with VecU softmax tiles in FlashAttention-3?
2. ~~Should the K-axis accumulator be INT32 instead of INT24 for headroom?~~ **Resolved 2026-07-20** (`pv_accumulator_width.py`): split it — INT24 for hidden-dim reductions, **INT32 for the INT8 P·V token-reduction path** (not headroom, a hard requirement — INT24 overflows on a flat attention tile past ~520 tokens). See the `arch.yml` accumulator_rationale.
3. INT8×INT8 fallback mode — implement as separate PE multiplier or as INT4 × 2 emulation? Affects gate count.
