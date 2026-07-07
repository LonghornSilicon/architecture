# KVE — KV Cache Engine (ChannelQuant)  [dir kept as `kce/` for HLS continuity]

**Spec source:** `../../../arch.yml` block `kv_compression_engine` and definitive `KVE`.

> **Codec-of-record note (2026-06-22 pivot):** the codec of record is **ChannelQuant**, not TurboQuant. The full block lives in the `kv-cache-engine` repo. The directory name `kce/` and any `kce`/`hadamard16` code identifiers are retained for HLS continuity, but the block is the **KVE (KV Cache Engine)**. Everything in the "legacy" sections below (16-pt Walsh-Hadamard butterfly, Lloyd-Max codebook, 4.0 bpe, 0.08 mm², compressed-domain INT3 scoring, the five TurboQuant CSR modes) predates the pivot and is **pending human re-derivation for ChannelQuant** — do not treat it as the current design.

## What this block is (codec of record)

- **Headline research IP:** first-silicon streaming implementation of the **ChannelQuant** KV codec.
- **ChannelQuant:** per-channel INT4 keys (grouped, G=128) + per-token INT4 values + a **static top-k FP16 outlier-channel lane**.
- Tiers: **CQ-8, CQ-4, CQ-4+.** ~3.8× KV compression at ~4 bits/value, near-lossless (HellaSwag acc_norm within ~0.4–0.8 pt of FP16 at CQ-4+ on Qwen2-0.5B/1.5B).
- Recipe follows **KIVI (ICML 2024) / KVQuant (2024)**; Longhorn's contribution is the streaming silicon implementation.
- Area/power: **pending re-derivation** (the 0.08 mm² / 0.05 W figures below are legacy TurboQuant-era).

## LEGACY (pre-2026-06-22 TurboQuant design — pending re-derivation)

- 16-point Walsh-Hadamard butterfly (64 add/sub, 4 stages × 8 pairs) — zero multipliers, just sign-pattern adds
- 8-centroid Lloyd-Max codebook (3-bit indices) — nearest-centroid via 7 comparators × 16 lanes
- Bit-pack: 16 elements × 3 bits + 16-bit FP16 group scale = 64 bits per 16 elements = 4.0 bpe effective → 4.0× vs FP16
- 0.08 mm² target at 16nm; 0.05 W

### Legacy five CSR-selectable modes (TurboQuant-era; pending re-derivation)

| Mode | bpe | Compression | Implementation |
|---|---|---|---|
| `turboquant_3bit_16pt` (primary) | 4.0 | 4.0× | Lloyd-Max 8-centroid; ROM 64B |
| `hadamard_int4_16pt` (fallback) | 5.0 | 3.2× | Linear INT4 quant, same Hadamard |
| `turboquant_asymmetric_K3V2` (prod) | 3.5 avg | 4.57× | K @ 4 bpe, V @ 3 bpe; alt ROM |
| `fp4_e2m1_codebook` | 4.0 | 4.0× | NVFP4 levels {0,0.5,1,1.5,2,3,4,6}; alt 64B ROM |
| `bypass_fp16` (debug) | 16 | 1× | Passthrough |

## Critical correctness property (legacy TurboQuant claim — pending re-derivation)

Under the legacy TurboQuant design the decode path required ZERO multipliers (inverse Hadamard butterfly + 8-entry LUT lookup only), which is what made compressed-domain attention scoring viable in MatE (K read in compressed form, never expanded to FP16). Whether ChannelQuant preserves a comparable compressed-domain read path is **pending re-derivation**.

## Files

- `kce.h`, `kce.cpp` — top-level Stratus entity
- `hadamard16.h` — 16-pt Walsh-Hadamard butterfly (parameterizable)
- `codebook.h` — Lloyd-Max 8-centroid classifier + bit-pack
- `tb/` — testbench validating bit-exact against Python golden (peer of `stratus/`)
- `stratus/project.tcl` — Stratus HLS project (canonical syntax in [`../../../docs/tools-overview.md`](../../../docs/tools-overview.md))
