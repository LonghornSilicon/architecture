# Longhorn Silicon — Architecture

UT Austin AI accelerator project. **Current target: Lambda — a 4 mm² ASIC on TSMC N16FFC, taped out via IMEC / Europractice mini@sic 2.0.** Two architecture candidates at the same 4 mm² budget; the team picks one:

- **Lambda v1** — KV cache + compressed-domain attention coprocessor (pairs with host)
- **Lambda v2** — standalone end-to-end mini-accelerator (LPDDR4X, runs the model on-die)

*Lambda* is the codename: **L**onghorn **A**ccelerator for **M**atrix-**B**ased **D**ataflow & **A**ttention.

---

## Where to start

| If you want to know… | Read |
|---|---|
| **Current state + v1/v2 comparison + next moves** | [`STATUS.md`](STATUS.md) |
| **Lambda v2 floorplan + full specifications (browser-friendly)** | [`archs/lambda/Lambda_v2_floorplan.html`](archs/lambda/Lambda_v2_floorplan.html) |
| Lambda v2 unit-by-unit dataflow walkthrough (teaching doc) | [`archs/lambda/Lambda_v2_dataflow_walkthrough.md`](archs/lambda/Lambda_v2_dataflow_walkthrough.md) |
| Lambda v2 machine-readable spec (every number with citation) | [`archs/lambda/Lambda_v2_4mm2.yaml`](archs/lambda/Lambda_v2_4mm2.yaml) |
| Lambda v1 spec — conservative 4 mm² (KV coprocessor) | [`archs/lambda/Lambda_v1_4mm2.yaml`](archs/lambda/Lambda_v1_4mm2.yaml) |
| Design-space validation scripts (Python, stdlib only) | [`scripts/v2_design_space/`](scripts/v2_design_space/) |
| Circuit-level optimization research runs | [`roadmap.md`](roadmap.md) |
| Predecessor on SKY130 (LASSO; KCE block carries forward) | [`PRDs/lasso-v0-original/`](PRDs/lasso-v0-original/), [`PRDs/lasso-v1-prudent/`](PRDs/lasso-v1-prudent/), [`archs/lasso/`](archs/lasso/) |

---

## Repo structure

```
architecture/
├── README.md                                this file (entry point)
├── STATUS.md                                v1 vs v2 comparison + open questions
├── roadmap.md                               circuit-level optimization roadmap
├── archs.yaml                               legacy LASSO design-space comparison
│
├── archs/
│   ├── README.md
│   ├── _shared/                             cross-arch constants, citations, eval axes
│   ├── lambda/
│   │   ├── Lambda_v1_4mm2.yaml              ★ conservative 4 mm² — KV coprocessor
│   │   └── Lambda_v2_4mm2.yaml              ★ ambitious 4 mm² — standalone mini-accelerator
│   └── lasso/
│       ├── LASSO_A2_prudent_int4.yaml       LASSO archived — prudent baseline (SKY130)
│       ├── LASSO_A3_turboquant_minimal.yaml LASSO archived — 2-block TurboQuant (SKY130)
│       ├── LASSO_A3plus_turboquant_extended.yaml  LASSO archived — KCE inheritance source
│       └── LASSO_A4lean_full_stack.yaml     LASSO archived — 4-block + TurboQuant
│
└── PRDs/
    │   ├── _ARCHIVED_README.md
    │   ├── PRD.md
    │   ├── design-rationale.md
    │   └── floorplan.html
    ├── lasso-v1-prudent/                    archived (SKY130 prudent baseline)
    │   └── PRD.md
    └── lasso-v0-original/                   archived (SKY130 original 4-block)
        ├── PRD.md
        ├── design-rationale.md
        └── floorplan.html
```

The reorganization (2026-04-26) cleanly separates Lambda from LASSO at every level: in `archs/` (subfolders by chip series, plus prefix in LASSO filenames), in `PRDs/` (subfolders), and in the YAML metadata. Only one chip target lives in `archs/lambda/` — Lambda v1 and Lambda v2 are two architecture candidates at the same 4 mm² die budget, not two chip generations.

---

## Project context

- **Process:** TSMC N16FFC at 28.2 MTr/mm², ~1.25 MB/mm² HD SRAM, 0.8 V core, 1 GHz target
- **Shuttle:** IMEC / Europractice mini@sic 2.0 (primary) or Muse Semiconductor (US fallback) — both routes to the same TSMC University FinFET program
- **Die budget:** **4 mm² (2×2 mm), ~$60-100K shuttle cost** via IMEC academic-discount path
- **Advisor / lab:** UT Austin computer architecture lab head; supports the IMEC and TSMC University FinFET shuttle path
- **Target tape-out:** Q1 2028, demo Q3 2028, paper at DAC/ICCAD/MICRO/HotChips student session 2028-09
- **Naming history:** the chip codename was briefly "BEVO" in earlier drafts; that has been retired throughout the repo — anyone still saying "BEVO" means Lambda. The earlier 25 mm² "flagship" target was abandoned because the shuttle cost (~$400-500K) was unfundable; the canonical specification now lives entirely in `archs/lambda/` (YAML + walkthrough + floorplan).
