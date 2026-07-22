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
│   │   ├── mate/                 #   mate_pv, mate_pv_fp16, mate_qkt (+ tb)
│   │   ├── vecu/                 #   vecu_softmax (+ future rope, rmsnorm)
│   │   ├── precision_controller/
│   │   └── README.md
│   ├── kve/                      # from kv-cache-engine
│   ├── tiu/                      # from token-importance-unit
│   └── lambda_acu_top/           # integration top + decode FSM (Phase 3)
├── sw/reference_model/           # golden models (merged from each repo's sw/)
├── verif/cosim/                  # tb_chip_cosim (from architecture)
├── pdk/
│   ├── sky130/                   # per-block OpenLane configs + results
│   └── gf180/                    # from chipathon-lambda-acu (LibreLane + padring + SPI)
├── research/                     # the archived APA RL project (or its own repo)
└── .github/workflows/            # CI + mirror-blocks.yml
```

Mirror map: `rtl/acu → lambda-acu`, `rtl/kve → lambda-kve`, `rtl/tiu → lambda-tiu` (extend as
MSC/LSU/HIF land).

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

## Decisions to confirm before executing

- **Monorepo home:** rename/rebrand `architecture` → `lambda`, or a fresh `lambda` repo? (Reusing
  `architecture` keeps its history + doc-hub role; a fresh repo is a clean slate.)
- **Research split:** archive the APA RL project into `research/` *inside* the monorepo, or give it
  its own standalone `adaptive-precision-attention` repo (it's a real publication — arguably wants
  its own front door too)?
- **`rtl/acu` hierarchy:** subdirs (`mate/`, `vecu/`) as above, or flat like KVE? (Subdirs read
  better for a multi-block unit; flat matches KVE's precedent.)
- **RTL/PDK split:** today it's branch-based (`rtl` vs `main`) + a separate PDK repo. In the
  monorepo it becomes directory-based (`rtl/` + `pdk/`) on one branch. Confirm that's the intent.

## Risks / notes

- `git subtree split` re-walks history each mirror run — fine here; swap to `josh` if it ever slows.
- Mirror repos are **read-only**; document that in each mirror's README so contributors go to the mono.
- The cutover should be **one atomic reorg**, not piecemeal, to avoid a long window of broken paths.
- Nothing is moved until the in-flight sign-offs land and the four decisions above are made.
