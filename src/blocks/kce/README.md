# KCE-mini — KV Compression Engine (TurboQuant 16-pt)

**Spec source:** `../../../arch.yml` block `kv_compression_engine` and definitive `KCE`.

## What this block is

- **Headline research IP.** First-silicon implementation of TurboQuant (Ashkboos et al., arXiv 2504.19874, ICLR'26) at a competitive node.
- 16-point Walsh-Hadamard butterfly (64 add/sub, 4 stages × 8 pairs) — zero multipliers, just sign-pattern adds
- 8-centroid Lloyd-Max codebook (3-bit indices) — nearest-centroid via 7 comparators × 16 lanes
- Bit-pack: 16 elements × 3 bits + 16-bit FP16 group scale = **64 bits per 16 elements = 4.0 bpe effective → 4.0× compression vs FP16**
- 0.08 mm² target at 16nm; 0.05 W

## Five CSR-selectable modes

| Mode | bpe | Compression | Implementation |
|---|---|---|---|
| `turboquant_3bit_16pt` (primary) | 4.0 | 4.0× | Lloyd-Max 8-centroid; ROM 64B |
| `hadamard_int4_16pt` (fallback) | 5.0 | 3.2× | Linear INT4 quant, same Hadamard |
| `turboquant_asymmetric_K3V2` (prod) | 3.5 avg | 4.57× | K @ 4 bpe, V @ 3 bpe; alt ROM |
| `fp4_e2m1_codebook` | 4.0 | 4.0× | NVFP4 levels {0,0.5,1,1.5,2,3,4,6}; alt 64B ROM |
| `bypass_fp16` (debug) | 16 | 1× | Passthrough |

## Critical correctness property

**Decode path requires ZERO multipliers.** Inverse Hadamard butterfly + 8-entry LUT lookup only. This is what makes compressed-domain attention scoring viable in MatE: K is read in compressed form, never expanded to FP16. The KCE inverse path is on the read side for ablation/debug; the primary path is reading raw 3-bit indices directly from kv_scratchpad into MatE's INT3 multiplier port.

## Files

- `kce.h`, `kce.cpp` — top-level Stratus entity
- `hadamard16.h` — 16-pt Walsh-Hadamard butterfly (parameterizable)
- `codebook.h` — Lloyd-Max 8-centroid classifier + bit-pack
- `tb/` — testbench validating bit-exact against Python golden
- `stratus.tcl`
