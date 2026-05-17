# MatE — Matrix Engine (8×8 INT8×INT4 systolic)

**Spec source:** `../../../arch.yml` block `matrix_engine` (lines look for `id: matrix_engine`).

## What this block is

- 8×8 grid = 64 INT8×INT4 PEs at 1 GHz → 128 GOPS peak, 76.8 GOPS sustained at 60% util
- Weight-stationary primary dataflow (Q/K/V proj, FFN, logits)
- Output-stationary alt dataflow for Q·K^T (Q pinned, K streams from kv_scratchpad)
- Compressed-domain attention scoring: INT8 (Q) × INT3 (compressed K codebook idx)
- **INT16 partial-product register inside each PE; INT24 K-axis accumulator at column output** (correction from earlier "INT16 accumulator" spec bug — see `STATUS.md` §4 #3)
- 0.10 mm² target at 16nm; 0.32 W at 50% util

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

Build output lands under `<repo>/build/mate/stratus/<config>/` (gitignored).

## Open design questions for the team

1. Output-stationary mode CSR — is the per-tile mode switch fast enough to interleave with VecU softmax tiles in FlashAttention-3?
2. Should the K-axis accumulator be INT32 instead of INT24 for headroom? Marginal area cost; matches TPU convention.
3. INT8×INT8 fallback mode — implement as separate PE multiplier or as INT4 × 2 emulation? Affects gate count.
