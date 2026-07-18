# End-to-end RTL cosim — KVCE + APA + TIU

Runs the three built LonghornSilicon block RTLs together in **one** iverilog
simulation, driven by **one real Qwen2-0.5B attention slice**, wired in chip order:

```
KVCE (cq_value_path, CQ-8)   compress+decompress K,V  ->  K̂, V̂
  in-sim                     S = Q · K̂                (attention scores)
APA  (precision_controller)  route the score tile      ->  INT8 / FP16 decision
  in-sim                     P = softmax(S)
TIU  (token_importance_unit) accumulate P, evict        ->  heavy-hitter victim
  in-sim                     O = P · V̂                 (attention output)
```

Each block **self-checks** against its own rule recomputed in the testbench on the
**same RTL-derived data** — the scores fed to the precision controller come from the
KVCE's actual decompressed K̂, and the weights fed to the TIU come from their softmax.
Per-block bit-exactness is already covered by each repo's own testbenches; this proves
the three blocks **interoperate on a coherent dataflow**.

Result (`make sim`): **9/9 checks pass** — 1 APA routing decision + 8 TIU eviction
victims — on the frozen slice (`trace.hex`, layer 6 / head 0, D=64, T=16, budget C=8).

## Run
```sh
make sim                       # uses the committed trace.hex (no torch needed)
# regenerate the slice (needs torch + transformers):
python gen_integration_trace.py --model Qwen/Qwen2-0.5B --layer 6 --head 0 --T 16 --C 8
```

## Assumptions
The Makefile references the three block repos as **siblings** of this repo
(`../../../kv-cache-engine`, `../../../adaptive-precision-attention`,
`../../../token-importance-unit`); override `LHS=` if they live elsewhere. Needs
`iverilog` (12.0). The KVCE codec is driven at the `cq_value_path` core (CQ-8 tier);
the grouped per-channel key path and the full AXI top are exercised by the KVCE repo's
own `sim_kpath` / `sim_top`.
