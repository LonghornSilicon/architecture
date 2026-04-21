# LASSO Architecture Design-Space Directory

Disaggregated per-architecture design-space exploration files. Each candidate architecture is a standalone YAML with its own blocks, knobs, trade-offs, risks, and fit scores. Shared constants (process parameters, algorithms, citations, risks, evaluation axes) live in `_shared/` and are referenced — not duplicated — by each per-architecture file.

**Source of truth hierarchy:**
- This directory (`archs/*.yaml`) — per-architecture explorable design spaces with knobs
- `../archs.yaml` (parent dir) — the master comparison + decision matrix + sensitivity analysis
- `../PRD.md`, `../PRD-v1-prudent.md` — committed architecture specifications
- `../design-rationale.md` — why decisions were made

The parent `archs.yaml` is the answer to *"which architecture should we pick?"*. The files in this directory are the answer to *"for each candidate, what are the knobs, and what does sweeping them do?"*.

## Directory structure

```
archs/
├── README.md                             ← this file
├── _shared/
│   ├── process.yaml                      ← SKY130, Caravel, density constants
│   ├── algorithms.yaml                   ← INT4, Hadamard-INT4, TurboQuant, FP4 specs
│   ├── citations.yaml                    ← reference-paper bibliography [C-xx]
│   ├── evaluation_axes.yaml              ← scoring dimensions and weights
│   └── shared_risks.yaml                 ← risks that apply to every candidate
├── A2_prudent_int4.yaml                  ← safe fallback baseline — "always ships"
├── A3_turboquant_minimal.yaml            ← 2-block TurboQuant — "conservative ambitious"
├── A3plus_turboquant_extended.yaml       ← 2-block TurboQuant + QJL + compressed Q·K + FP4 mode
└── A4lean_full_stack.yaml                ← 4-block + TurboQuant, no DMA — "max ambition that ships"
```

## Which architectures are in this directory (and why)

Only architectures genuinely worth exploring. Two candidates from earlier analysis were **deliberately excluded**:

| Excluded | Reason |
|---|---|
| A1 (original 4-block INT4, no TurboQuant) | Strictly dominated by A4-lean, which has the same blocks plus a 2026-frontier algorithm. Keeping A1 as an option is just hedging against a weaker outcome — no reason to. |
| A4-full (4-block + TurboQuant + DMA) | DMA engine verification alone is ~8 person-months (40 tests). No unique research claim is gained by hardening DMA in silicon; the host moves bytes fine. GDSII confidence drops below 40%, not worth the risk. |

## How to use these files

### If you're picking an architecture
Start at `../archs.yaml` decision matrix. Then read the chosen candidate's file here for its specific design-space knobs and trade-offs.

### If you're already committed to an architecture
Read the matching file here and resolve every item in its `critical_decisions` block. Each decision has an explicit deadline — these gate the PRD draft.

### If you want to sweep a parameter
Find the parameter in `design_space.*` of the relevant file. The `trade_offs` section tells you what each value costs and buys. If the sweep changes multiple architectures (e.g., "compare bank counts across A3⁺ and A4-lean"), cross-reference the same knob in both files.

### If you want to add a new architecture
Copy one of the existing files as a skeleton, change the `id`, fill in the schema. Keep the schema consistent so programmatic comparison across files keeps working. Add the new file to this README and to `../archs.yaml`'s architecture list.

## Schema contract

Every architecture file follows the same top-level keys, in this order:

```yaml
id:                    # short identifier, matches filename
name:                  # human-readable
tier:                  # prudent | ambitious | stretch
status:                # candidate | proposed | recommended | fallback
one_line_summary:      # ≤ 140 chars
depends_on:            # references to _shared/ files and algorithms
research_narrative:    # paper angle, novelty strength 1–10, differentiation
blocks:                # list of hardware blocks with area and verif
resource_summary:      # area + test + person-month totals
design_space:          # explorable knobs with trade-offs
capabilities:          # what the chip can do end-to-end
verification:          # test count + effort estimate
fit_scoring:           # per-axis 1–10 matches evaluation_axes.yaml
risks:                 # architecture-specific; shared risks are in _shared/
open_questions:        # things this file does not resolve
critical_decisions:    # decisions required before PRD draft
```

## Editing rules

- Every numeric claim must cite `[C-xx]` (from `_shared/citations.yaml`) or be explicitly tagged `estimate: true`. Never launder an estimate into a fact.
- Never weaken a risk to make an architecture look better.
- If a shared constant changes (e.g., SRAM density), update it once in `_shared/` and do not duplicate in per-arch files.
- Keep `critical_decisions` short and dated. Every unresolved decision is a potential PRD-blocker.
- New knobs in `design_space` must include a `trade_offs` table showing what each value costs and buys.
