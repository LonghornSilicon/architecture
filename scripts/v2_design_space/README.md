# Lambda v2 Design-Space Validation Scripts

Self-contained Python (stdlib only) that stress-tests every load-bearing assumption in `archs/lambda/Lambda_v2_4mm2.yaml`. Run them to verify or correct the YAML's numbers before committing engineering effort.

## What's here

| Script | Question it answers |
|---|---|
| `lambda_v2_audit.py` | Top-level: runs every other check and produces a single grounded report. **Start here.** |
| `roofline.py` | What's the largest reasonable model under (PHY_bandwidth, tok/s) constraint? Bandwidth-bound vs compute-bound regime. |
| `area_audit.py` | Sweep PHY widths × MatE sizes × SRAM sizes against a 4 mm² die budget. Find Pareto-optimal points. |
| `kv_capacity.py` | For each candidate target model (Llama-3.2-3B, Qwen2.5-3B, Phi-3.5-mini, etc.), what context fits in the scratchpad? |
| `power_budget.py` | Per-block + total power at the v2 baseline, with sensitivity analysis. |
| `model_fit.py` | Given (PHY width, target tok/s threshold), enumerate the model classes that fit. |

## How to run

```bash
cd scripts/v2_design_space
python3 lambda_v2_audit.py            # produces audit report on stdout
python3 lambda_v2_audit.py > report.txt   # captures to file
```

Or run individual scripts:

```bash
python3 roofline.py
python3 area_audit.py
python3 kv_capacity.py
python3 model_fit.py
python3 power_budget.py
```

## Ground-truth references baked in

Every numeric assumption in these scripts cites the source. Top sources:

- **TSMC 16nm 6T HD bitcell = 0.07 µm²** — IEEE/TSMC published, multiple references
- **TSMC 16nm 2-port 256kb SRAM macro = 6.05 Mb/mm²** — IEEE 2016
- **LPDDR5X-8533 = 17.07 GB/s peak per 16-bit channel** — JEDEC LPDDR5X spec
- **LPDDR5X power = ~7.5 mW/Gbps system** — Micron/Samsung product briefs (25% better than LPDDR5)
- **OPENEDGES LPDDR5/4 PHY validated in silicon at 16nm** — design-reuse press release
- **W4A8 quality preservation 95-98% for 3B-class with AWQ** — multiple 2024-26 quantization eval papers
- **TurboQuant 3.5 b/elem quality-neutral on LongBench/NIH** — ICLR'26 (arXiv 2504.19874)

## When script outputs disagree with the YAML

Update the YAML, not the script. The scripts derive from first principles + published references; the YAML is a snapshot that may have drifted. Document each correction in the YAML's `verification_log`.
