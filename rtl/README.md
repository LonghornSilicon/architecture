# Cross-block RTL cosim — LonghornSilicon "Lambda"

First **cross-block** integration of the three live block RTLs. Each block is verified
bit-exact in its own repo's `rtl` branch; this harness proves they **co-simulate on one
shared attention tile** and each still matches its reference in-context.

> **Process node.** The vendored RTL is a **130nm Sky130 proxy**. Lambda targets **TSMC
> 16nm**; Sky130 is the best open PDK we have, used only to get gate-level area/latency
> *estimates* that we scale to 16nm. Timing/area numbers here are proxy figures, not the
> 16nm silicon.

## What runs (`make cosim`)

One real-Qwen attention tile (`vectors/qwen_val.hex` = V rows, `vectors/qwen_vhatwht.hex`
= their reference V̂) drives all three blocks in chip order:

| Block | RTL | Checked |
|---|---|---|
| **KVE** (block 2) | `cq_value_path_wht` → `wht_inverse_out` (CQ-3-rot, Path B) | reconstructed V̂ **bit-exact** vs the vendored reference, per token |
| **TIU** (block 3) | `token_importance_unit` (H2O) | `tier_keep` = (mass ≥ threshold) **and** eviction victim = min-mass slot |
| **ACU** (block 1) | `precision_controller` | precision gate `max·N > 10·Σ` on a peaky score row → FP16 |

```
[KVE ] CQ-3-rot V̂ over 8 real-Qwen tokens: bit-exact vs reference
[TIU ] keep-tier (thr=128) + eviction victim: match reference (evict slot 3)
[ACU ] precision gate on a peaky score row: match reference (fp16=1)

CROSS-BLOCK COSIM (ACU + KVE + TIU on one shared tile): ALL BLOCKS PASS
```

## Scope / what this is *not*

- The **P·V MAC / MatE** datapath is HLS-only (not synthesizable SV yet), so it is **not**
  in this cosim — the KVE emits rotated V̂ and the `wht_inverse_out` MatE-output stage is
  exercised, but the INT8/FP16 accumulation tile between them is not.
- The KVE check is capped to 8 tokens (the fp16 WHT butterfly is combinational; 8 tokens is
  enough to prove bit-exactness in-context — the full 348,160-element proof lives in the
  kv-cache-engine `rtl` branch).
- `blocks/` is **vendored** from each block repo's `rtl` branch (kv-cache-engine, ACU,
  token-importance-unit). The per-block authoritative proofs run in those repos' CI.

## Reproduce

```sh
mkdir -p build && make cosim
```
