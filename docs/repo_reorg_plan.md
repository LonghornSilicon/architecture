# Repo Reorg Plan — Monorepo + Auto-Mirror

**Drafted 2026-07-22.** Goal: one **monorepo** for build/integration ergonomics, PLUS a
**standalone browsable/cloneable repo per block** (read-only auto-mirror) so we keep the
"open it up and see it" property. Prototype mirror workflow: `docs/prototypes/mirror-blocks.yml`.

## Why this shape (the "have both")

- **Monorepo** = one clone, atomic cross-block commits, one CI, trivial cosim/integration
  (`lambda_acu` top pulls MatE+VecU+KVE+PC from sibling dirs, not from pinned submodule SHAs).
- **Auto-mirror** = a CI job `git subtree split`s each block dir and force-pushes it to a
  standalone `lambda-<block>` repo → each block still has its own GitHub URL + README + clone,
  just read-only. PRs land on the monorepo; mirrors follow.
- Net: the developer experience is a monorepo; the *public face* is still per-block repos.

## Step 0 — Clean up the ACU repo FIRST (it's the messy one)

KVE and TIU are clean (born as block repos). The `attention-compute-unit` repo is messy because
it's still the original **"Adaptive Precision Attention" RL research project** with hardware
grafted on. Root-level clutter to resolve:

| Item | What it is | Disposition |
|---|---|---|
| `phase1_policy/`, `phase2_kernel/` | RL policy evolution + evolved kernel (research) | → `research/` (or a separate `adaptive-precision-attention-research` repo) |
| `kv_cache/`, `common/` | Python KV-cache + shared prototypes (research) | → `research/` |
| `run_phase1.sh`, `run_phase2.sh`, `requirements.txt` | research runners | → `research/` |
| `analysis/` (48 files) | benchmarks / sweeps (FA-2 compare, entropy) | → `research/analysis/` (keep — it backs the paper) |
| `paper/` | the APA method paper | keep (research artifact) |
| `rtl/`, `openlane/`, `orfs/`, `sw/reference_model/`, `docs/isa/` | **the actual hardware** | **keep — this is the ACU** |

**Target (matches KVE/TIU neatness):** repo root = `README.md`, `rtl/`, `sw/`, `openlane/`,
`orfs/`, `docs/`, `analysis/` (light), `research/` (the archived RL project), `.github/`.
Also: rename the README from "Adaptive Precision Attention" → "ACU — Attention Compute Unit"
and flatten the stray EDA tcl (`genus*.tcl`, `innovus.tcl`, `mmmc.tcl`) into `rtl/eda/` or drop
the unused Cadence stubs (we sign off with LibreLane/OpenLane, not Genus/Innovus).

**⚠️ Sequencing:** a Sky130-sign-off agent is *live in this repo right now* (adding
`openlane/mate_qkt/` + `openlane/vecu_softmax/`). **Do the ACU cleanup only after it finishes** —
concurrent file moves + its commits = merge pain. Cleanup is the first executed step, but it
waits on that agent.

## Target monorepo layout (`lambda`)

```
lambda/
├── README.md                     # chip overview + links to each block
├── arch.yml  docs/  paper/       # from `architecture`
├── rtl/
│   ├── acu/                      # from attention-compute-unit (cleaned)
│   │   ├── mate/                 #   mate_pv, mate_pv_fp16, mate_qkt (+ tb/ docs/ research/)
│   │   ├── vecu/                 #   vecu_softmax (+ future rope, rmsnorm) (+ tb/ docs/ research/)
│   │   ├── precision_controller/ #   (+ tb/ docs/ research/)
│   │   └── README.md
│   ├── kve/                      # from kv-cache-engine (+ docs/ research/)
│   ├── tiu/                      # from token-importance-unit (+ docs/ research/)
│   └── lambda_acu_top/           # integration top + decode FSM (Phase 3)
├── sw/reference_model/           # golden models (merged from each repo's sw/)
├── verif/cosim/                  # tb_chip_cosim (from architecture)
├── pdk/                          # each PDK its own folder; references rtl/ by path — NO copies
│   ├── sky130/                   # per-block OpenLane configs + results
│   ├── gf180/                    # from chipathon-lambda-acu (LibreLane + padring + SPI)
│   └── asap7/                    # ORFS predictive-7nm bracket (research)
├── research/                     # top-level: the APA RL project + chip-wide research
└── .github/workflows/            # CI + mirror-blocks.yml

# Every block dir (rtl/acu/mate, rtl/kve, …) carries its own README + docs/ + research/, so each
# mirror repo is self-describing and ships its design rationale as LLM/agent context (per decision #2).
```

**Mirror map** (per functional block — every block, incl. TIU; extend the row list as new blocks land):

| monorepo path | mirror repo | level |
|---|---|---|
| `rtl/acu` | `lambda-acu` | **umbrella** — the assembled ACU (mate + vecu + pc + top) |
| `rtl/acu/mate` | `lambda-mate` | piece |
| `rtl/acu/vecu` | `lambda-vecu` | piece |
| `rtl/acu/precision_controller` | `lambda-precision-controller` | piece |
| `rtl/kve` | `lambda-kve` | block |
| `rtl/tiu` | `lambda-tiu` | block |
| *(future)* `rtl/msc`, `rtl/lsu`, `rtl/hif` | `lambda-msc`, … | block |

**Nested mirrors are fine and drift-free.** `subtree split` is per-prefix, so `lambda-acu` (the
whole `rtl/acu/`) and `lambda-mate` (`rtl/acu/mate/`) are both read-only projections of the *same*
source tree. MatE's files appearing in both is not drift — it's one authoritative copy seen through
two windows. The umbrella "shows the assembled ACU"; the pieces show focused blocks.

**Copy-drift elimination (a real benefit, not just tidiness):** the `chipathon-lambda-acu` repo today
holds **hand-synced `.sv` copies** of every block (tracked in `PROVENANCE.md`) — they can silently
drift from the source repos. In the monorepo there is **one** copy of each block; `pdk/gf180/` and
`pdk/sky130/` reference it by path. The drift hazard goes away entirely.

## Migration — least-friction, history-preserving

**Principle:** never copy-paste files (loses history + blame). Import each repo *with history*
into its monorepo path using `git subtree add` or (cleaner) `git filter-repo --to-subdirectory-filter`.

1. **Freeze** — land the in-flight work first (KVE PDN sign-off, mate_qkt/vecu_softmax Sky130,
   vecu_softmax GF180 re-harden). Migrating mid-flight multiplies conflicts.
2. **Clean the ACU repo** (Step 0) on its `rtl` branch; commit.
3. **Seed the monorepo** from `architecture` (it already holds docs/arch/cosim + is the doc hub) —
   or a fresh `lambda` repo. Move its own content into the target dirs.
4. **Import each block with history** into its path:
   `git filter-repo --to-subdirectory-filter rtl/kve` on a clone of kv-cache-engine, then pull it
   in; repeat for tiu, acu, and the GF180 PDK work. (Each block's full commit history is preserved
   under its new prefix.)
5. **Re-point flows** — the cosim `Makefile` include paths, the OpenLane/LibreLane `VERILOG_FILES`
   (`dir::...`), the ASAP7 ORFS `config.mk`, and CI. This is the bulk of the mechanical work.
6. **Stand up CI + the mirror** — port each repo's `.github` CI into the monorepo; add
   `mirror-blocks.yml` + create the empty `lambda-<block>` mirror repos + the `MIRROR_PAT` secret.
   First mirror push seeds them.
7. **Retire the old repos** — archive them (GitHub "Archive") with a README pointer to the monorepo,
   OR let the mirrors *become* them (point people at the read-only mirrors). Keep the git history —
   don't delete.

## Decisions — CONFIRMED 2026-07-22

1. **Monorepo home:** a **fresh repo named `lambda`** (final). Family symmetry with the per-block
   mirror repos (`lambda-mate`, `lambda-vecu`, `lambda-kve`, `lambda-tiu`, …).
2. **Research:** keep it **as a `research/` subdir** (NOT archived, NOT a branch, NOT its own repo).
   Two levels: a top-level `research/` in `lambda` (the APA RL project + chip-wide research), AND a
   **`research/` subdir inside each block dir**. Rationale (Chaithu): the per-block `research/` is
   **context for future LLM/agents** — design rationale, dead ends, benchmarks, exploration notes —
   so that anyone (human or agent) starting new work on that block, or a new related project, inherits
   the "why," not just the RTL. It rides along in the block's mirror repo, so the context is wherever
   the block is.
3. **`rtl` layout:** **subdirs for multi-block units, flat for single blocks.** `rtl/acu/` gets
   `mate/` + `vecu/` + `precision_controller/`; `rtl/kve/` and `rtl/tiu/` stay flat (one block each,
   even if many files). A unit gains subdirs only if it later holds multiple distinct blocks.
4. **RTL/PDK split:** **directory-based, both on `main`** — `rtl/` and `pdk/` are *folders*, not
   branches. `pdk/` splits **per target, each its own folder** — `pdk/sky130/`, `pdk/gf180/`,
   `pdk/asap7/` (we test on multiple PDKs, so each is a sibling folder).
5. **Mirror policy:** **every functional block gets its own mirror repo** — and every *new* block we
   make adds a mirror row. Granularity = the architecture's functional blocks (MatE, VecU, KVE, TIU,
   precision-controller, + future MSC/LSU/HIF), matching how we name blocks — not the flat leaf tiles
   (`mate_pv` etc. live *inside* `lambda-mate`). Each block dir carries its `research/` + `docs/` so
   the mirror is self-describing.

## Risks / notes

- `git subtree split` re-walks history each mirror run — fine here; swap to `josh` if it ever slows.
- Mirror repos are **read-only**; document that in each mirror's README so contributors go to the mono.
- The cutover should be **one atomic reorg**, not piecemeal, to avoid a long window of broken paths.
- Nothing is moved until the in-flight sign-offs land and the four decisions above are made.
