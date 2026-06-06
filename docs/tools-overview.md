# Lambda Chamber Tooling Framework

**What this is:** the convention for launching Cadence tools (Stratus HLS, Xcelium, Genus, Innovus, Virtuoso) from a teammate's `~/bin/` on the chamber, against the Lambda repo or any future project. Read once; reuse forever.

**Companion docs:**
- [`chamber-sync-setup.md`](chamber-sync-setup.md) — how the repo gets onto the chamber in the first place (git bundles + `sync-promote`).
- [`../arch.yml`](../arch.yml) — what the chip actually is.
- Block READMEs at [`../src/blocks/<block>/README.md`](../src/blocks/) — per-block spec.

---

## TL;DR

```bash
# One-time setup (per teammate, on the chamber — login node is fine for install)
sync-promote                                       # pull latest main
bash ~/architecture/tools/install.sh               # symlinks tools/bin/* into ~/bin/
                                                   # + provisions ~/work/lambda/{logs,inputs}
                                                   # + writes stub ~/work/lambda/Makefile

# Daily use — ALWAYS on a compute node (login node lacks the autofs-mounted tools)
qsh -q normal.q -now n -V                          # get a compute shell with X11

cd ~/work/lambda                                   # operate from the run area, NOT the repo
make diag                                          # chamber + lambda probe (autofs-aware)

# HLS (Stratus)
make gui          BLOCK=mate                       # Stratus IDE
make hls          BLOCK=mate CFG=BASIC             # headless cynth
make hls-report   BLOCK=mate CFG=BASIC             # tail latest HLS log

# Synthesis (Genus, Common UI)
make genus        BLOCK=mate                       # Genus + GUI
make genus-shell  BLOCK=mate                       # text REPL  (then `gui_show`)
make genus-batch  BLOCK=mate FLOW=synth            # headless flow

# Simulation (Xcelium xrun) + waveform debug
make sim          BLOCK=mate ARGS='-access +rwc ...'  # headless xrun
make sim-gui      BLOCK=mate ARGS='-access +rwc ...'  # SimVision live
make waves        BLOCK=mate                       # Verisium (Primary) / SimVision (fallback)

# Place & route (Innovus, Stylus Common UI)
make innovus      BLOCK=mate                       # Innovus + GUI (no design needed)
make innovus-shell BLOCK=mate                      # text REPL; then `gui_show`
make innovus-batch BLOCK=mate FLOW=setup           # headless

# Or call launchers directly from any CWD:
lambda-stratus  mate gui  /  lambda-genus mate gui  /  lambda-innovus mate gui
lambda-xcelium  mate sim <args>  /  lambda-verisium mate
chamber-diagnose                                   # raw chamber probe
```

That's the whole interface. Everything below is justification, mental models, and extrapolation paths. **Two facts to internalize first** — see "Chamber execution model" below: tools live on COMPUTE nodes only, `/apps` is AUTOFS.

---

## Chamber execution model

Three ground-truth facts about this chamber, all confirmed by a live debug session on **2026-06-06** (compute node `ip-10-2-6-68`). Anyone running the flow needs all three internalized — they reshape what "module avail" means.

### 1. `/apps/<TOOL>` is autofs — the catalog ≠ what's installed

`module avail` enumerates a global modulefile catalog at `/home/cm_admin/.../modulefiles/` — hundreds of tool×version combinations across the chamber's history. The actual software payload under `/apps/<TOOL>` is **automounted on demand**. Cold-listing `/apps/` from a shell shows only what is *currently mounted*; the rest appears the moment a `module load` (which appends `/apps/<TOOL>/bin` to `PATH`) and the next PATH scan touches the path. An earlier "Innovus isn't installed" call here was wrong — it was an `ls` of a cold automount. **All catalogued tools are present** once accessed.

Diagnostic implication baked into `chamber-diagnose` v0.4: the tool-availability check is now **load-then-test** (`module load <spec>` → `command -v <binary>`), not pre-load `command -v` (which always fails before the autofs trigger).

### 2. Tools live on COMPUTE nodes, not the login node

The login node (e.g. `ae03ut01`) carries only the heavy interactive tools (Virtuoso + vManager). The **digital + sim tools** (Stratus, Genus, Innovus, Xcelium, Pegasus, SSV, Verisium) automount on **compute nodes** reached via:

```csh
qsh -q normal.q -now n -V
```

The original `lambda-innovus mate gui` failure earlier in v0.3 was a login-node run, not a launcher bug. **Every launcher in v0.4 detects this** via `lambda_require_tool` (in `tools/lib/lambda-run.sh`): if a module loads but the binary doesn't appear on PATH, the error explicitly names the LOGIN-vs-compute distinction and prints the `qsh` command.

### 3. Module pins: three-level leaves matched to the installed family

Two-level specs like `innovus/251` are technically valid (Environment Modules resolves to the default leaf, e.g. `25.14-e035_1`). But v0.4 pins **three-level leaves** for two reasons that matter at org scale:

- **Reproducibility** — locks the version against silent default drift across nodes/time.
- **Matched release family** — Genus and Innovus on the *same* family share database format. Newest Genus on this chamber is `genus/211/21.18.000` (no 25x exists). So `innovus/211/21.18.000` is the matched pin; `innovus/251` (defaults to 25.14) would force a cross-version DB handoff (supported but ugly).

**Confirmed-installed matched set** (debug session 2026-06-06, on compute node `ip-10-2-6-68`):

| Tool | Module pin | Install path | Confirmed via |
|---|---|---|---|
| Stratus HLS | `stratus/2201/22.01.009` | `/apps/STRATUS2201/22.01.009` | v0.1 smoke test |
| Genus | `genus/211/21.18.000` | `/apps/GENUS211/21.18.000` | autofs touch + `module show` |
| Xcelium | `xcelium/2403/24.03.005` | `/apps/XCELIUM2403/24.03.005` | autofs touch + `module load` |
| Innovus (Stylus) | `innovus/211/21.18.000` | `/apps/INNOVUS211/21.18.000` | Stylus GUI brought up live |
| Verisium Debug | `verisiumdebug/2403/24.03.001` | TBD (binary name `verisium` is the first-run gate) | catalog only — fallback: `simvision` (ships in `XCELIUM2403`) |
| Pegasus (DRC/LVS) | `pegasus/232/23.24.000` | autofs (compute-node payload) | catalog only — usage deferred |
| SSV (Tempus/Voltus/Quantus) | `ssv/251/25.12.000` | autofs | catalog only — usage deferred |

Override any pin per-user in `~/.longhorn/lambda.env` (e.g., `export INNOVUS_MODULE=innovus/251/25.14-e035_1` if a project needs to switch families).

### 4. Tool flow — all-Cadence, no Calibre/PrimeTime

The chamber is 100% Cadence. The signoff path is:

```
Pegasus  (DRC/LVS — replaces Calibre)
Tempus / SSV  (STA — replaces PrimeTime)
Quantus  (parasitic extraction)
Voltus   (power/IR)
```

Earlier README/handoff prose that named Calibre + PrimeTime was wrong for this chamber; corrected in v0.4.

---

## Filesystem & run-area architecture

The repo, the run area, and the release artifacts each live in a different place. This is the org-scale decision in v0.4, and it's the single most important thing a new teammate needs to understand to avoid losing work to a `sync-promote`.

### Three storage classes, three locations

| Class | Variable | Default path | Synced? | Who writes |
|---|---|---|---|---|
| **Source / methodology** | `$LAMBDA_ROOT` | `~/architecture` | git mirror (RO) | humans |
| **Run / work** | `$LAMBDA_WORK` | `~/work/lambda` | no | tools |
| **Ephemeral** | `$LAMBDA_FAST` | `/tmp/$USER-lambda` | no | tools (fallback) |
| **Release / handoff** | (under `$LAMBDA_WORK`) | `~/work/lambda/<block>/release/` | no (manifested) | launchers, on success |

**Why home is the canonical run area:** the SFTP enum and the live debug confirmed there is no `/rscratch/$USER` provisioned (catalog dir exists; `/rscratch/schwartz` does not), no team-group dir under `/projects/`, and `/tmp` is node-local + wiped on reboot. **NFS home is the only reliable persistent writable space cross-node.** A `/projects/<group>/lambda` request to chamber admin is the escalation path for full-chip-scale runs (home quota).

**Why outside the repo:** `sync-promote` does `git reset --hard origin/main` on `~/architecture`. Tool output landing inside the mirror would be destroyed by every sync. In v0.1-v0.3 it survived only because `build/` was gitignored — luck, not design, broken by `git clean`.

### Layout under `$LAMBDA_WORK`

```
~/work/lambda/                        ($LAMBDA_WORK; home-backed; NOT in git)
├── Makefile                          stub: include $HOME/architecture/Makefile
├── logs/                              all launcher logs (xxx.<block>.<mode>.<ts>.log)
├── inputs/                            non-git inputs delivered by SFTP
│                                       (vendor IP, future team PDK, etc.)
└── <block>/                            mate, kce, vecu, tiu, msc, lsu, hif
    ├── stratus/<CFG>/                 HLS RTL + bdw_work    (lambda-stratus)
    ├── genus/
    │   ├── interactive/                 gui / shell sessions (stable dir)
    │   ├── <run-id>/                   batch run (UTC YYYYMMDD-HHMMSS)
    │   │   ├── outputs/<b>.mapped.v
    │   │   ├── reports/{timing,area,power}.rpt
    │   │   └── genus.log, genus.cmd
    │   └── latest -> <run-id>          symlink to newest
    ├── xcelium/
    │   ├── <run-id>/
    │   │   ├── xcelium.d/              compile DB
    │   │   ├── xrun.log
    │   │   └── waves.shm/              (if -access +rwc)
    │   └── latest -> <run-id>
    ├── verisium/<session>/             debug session state (reads ../xcelium/latest/waves.shm)
    ├── innovus/
    │   ├── interactive/                 gui / shell sessions
    │   ├── <run-id>/                   batch
    │   │   └── outputs/<b>.routed.{def,v,gds}
    │   └── latest -> <run-id>
    └── release/                        STABLE cross-stage handoff + MANIFEST
        ├── <b>.mapped.v                genus → innovus
        ├── <b>.routed.{def,v,gds}      innovus → pegasus
        └── MANIFEST                    UTC, tool, run-id, git sha per artifact
```

**run-id** = UTC `YYYYMMDD-HHMMSS`; the `latest` symlink in each tool dir points at the newest batch. **GUI/shell** sessions use a stable `interactive/` dir (no timestamp clutter). **Batch never clobbers** prior runs — preserves reproducibility + parametric sweeps. The `release/` contract decouples a messy run from the current-good artifact: the next tool reads from `release/`, not from a sibling's run dir.

### You operate from `~/work/lambda`

```bash
cd ~/work/lambda
make genus BLOCK=mate                  # outputs land in ~/work/lambda/mate/genus/...
```

Methodology comes from the versioned repo via the stub `Makefile`'s `include $(HOME)/architecture/Makefile`. Launchers (`~/bin`, on PATH from `tools/install.sh`) work from any CWD. This is the best-of-both — the user's intuition that "you should run from the schwartz space, not the repo" is exactly right and now enforced by the architecture.

---

## Architecture

Two layers, both shipping inside this repo. The split is deliberate so that the generic layer extrapolates to future projects without modification.

```
┌─────────────────────────────────────────────────────────────────┐
│ Project-scoped layer (knows Lambda blocks)                      │
│ tools/bin/lambda-stratus, lambda-diagnose                       │
│   resolves <block> -> src/blocks/<block>/stratus/project.tcl    │
│   delegates to ────────────────────────────────────┐            │
└──────────────────────────────────────────────────────│──────────┘
                                                       ▼
┌─────────────────────────────────────────────────────────────────┐
│ Generic layer (project-agnostic; takes paths)                   │
│ tools/bin/stratus-gui, stratus-batch, chamber-diagnose          │
│   sources tools/lib/lambda-env.sh + lambda-detach.sh            │
│   loads modules, checks X11, runs the tool                      │
└─────────────────────────────────────────────────────────────────┘
```

**Mental model:**

| Layer | Knows | Used when |
|---|---|---|
| **Project-scoped** | Lambda blocks (mate/kce/vecu/tiu/msc/lsu/hif), per-block file layout | Daily use: `lambda-stratus mate gui` |
| **Generic** | Tool invocation conventions, module pins, X11/license preflight | Any project, any directory: `stratus-gui project.tcl` |
| **Library (sourced)** | Env vars, default paths, module init, GUI detach helper | Sourced by both layers; never invoked directly |

Why two layers and not one: when the team starts a second project (LPDDR test chip, custom analog block, etc.), the generic layer drops in unchanged. Only a new thin project-scoped wrapper has to be written.

---

## Repo layout

```
~/architecture/
├── tools/
│   ├── install.sh                  # one-time installer; symlinks tools/bin/* into ~/bin/
│   ├── bin/                        # every file here gets symlinked into ~/bin/
│   │   ├── stratus-gui             # GENERIC: open IDE on a project.tcl in CWD
│   │   ├── stratus-batch           # GENERIC: cynth <config> on a project.tcl in CWD
│   │   ├── chamber-diagnose        # GENERIC: X11/modules/storage/license probe
│   │   ├── lambda-stratus          # PROJECT: <block> resolver + delegates to generic
│   │   └── lambda-diagnose         # PROJECT: chamber-diagnose + Lambda repo checks
│   └── lib/                        # NOT symlinked; sourced by tools/bin/* scripts
│       ├── lambda-env.sh           # default paths, module pins, module init
│       └── lambda-detach.sh        # gui_detach() helper (csh-safe GUI backgrounding)
│
├── src/blocks/<block>/
│   ├── <block>.h, <block>.cpp      # SystemC HLS source (when written)
│   ├── tb/                         # PEER to stratus/; survives a tool change
│   │   ├── main.cpp                # sc_main entry
│   │   └── system.{h,cpp}          # SC_MODULE testbench
│   └── stratus/                    # Stratus HLS project
│       ├── project.tcl             # define_hls_module + sources + targets
│       ├── hls.tcl                 # define_hls_config (when more configs land)
│       └── memgen.tcl              # memory generator config (when needed)
│
└── build/                          # gitignored: regenerable RTL + reports + logs
    └── <block>/stratus/<config>/   # where Stratus dumps generated RTL
```

After `bash tools/install.sh`, `~/bin/` contains symlinks back into `tools/bin/`. `sync-promote` keeps them current automatically (symlink, not copy).

---

## Mental models

### Verified Stratus 22.01.009 Tcl syntax

Ground-truth syntax (verified against ESP Columbia `accelerators/stratus_hls/spmv/stratus/project.tcl` + the live `stratus_ide` help on `ae03ut01`):

```tcl
define_hls_module <module-name> <source-files>
define_hls_config <module-name> <config-name> --clock_period=<val> [-DMACRO=val ...]
define_sim_config <sim-config-name> "<module> BEH" -argv "[list <tb-args>]"
```

Rules nailed down during v0.1 bring-up:

1. **`define_hls_config` requires `<module> <config>`** — module name MUST come first. Calling `define_hls_config BASIC` alone errors with `wrong # args: should be "define_hls_config moduleSpec ccName args"`.
2. **Clock-period syntax is `--clock_period=<val>`** — double-dash, equals sign, no space.
3. **Macro defines (`-DMACRO=val`) go after the config name**, never as the config name itself. Calling `define_hls_config BASIC -DCLOCK_PERIOD=1.0` parses `-DCLOCK_PERIOD=1.0` as a second config name and fails because it's not a legal C++ identifier.
4. **`stratus_ide -project <file>`** is the correct launcher flag (not `-prj`).

### Stratus HLS — the IDE is a project workspace, not an editor

The single most important thing to internalize: **Stratus IDE does not edit your source files.** It opens a `project.tcl`, reads the file paths listed there, and presents a workspace view of your design (source tree, synthesis-target list, Tcl console, schedule viewer, datapath analyzer). Your actual editing happens in your editor of choice — `gvim`, `emacs`, VS Code Remote-SSH, whatever — on files at `src/blocks/<block>/`.

The flow:

1. **Edit C++/SystemC source** in your editor. Files live under `src/blocks/<block>/{*.h,*.cpp,tb/*.cpp}`.
2. **Author or update `stratus/project.tcl`** to list those source paths, name the top `define_hls_module`, pick a clock period, define one or more `define_hls_config <name>` entries.
3. **`lambda-stratus <block> gui`** loads the module, checks X11, launches `stratus_ide -prj project.tcl` detached. The GUI opens with the source tree + your synthesis targets in a sidebar.
4. **Run `cynth BASIC`** from the GUI menu (or from a Tcl console pane). Stratus reads the C++ source, applies HLS, emits Verilog RTL under the project's working dir.
5. **For CI / overnight regression / scripted iteration:** `lambda-stratus <block> batch BASIC` does the same thing headlessly. Identical output. The GUI is for inspection, not source-of-truth.

The pragmas (`HLS_PIPELINE_LOOP`, `HLS_MAP_TO_REG_BANK`, etc.) live in the C++ source. The constraints (clock period, target lib, optimization mode) live in `project.tcl` / `hls.tcl`. Both are version-controlled.

### Xcelium — `xrun` is one command that does compile + elaborate + simulate

When you write a SystemC TB for HLS verification, you have two paths:
- **Stratus-driven `csim`** (preferred for per-block): Stratus invokes Xcelium internally with the test bench files listed in `define_sim_config`. You run `csim BASIC` from the same console as `cynth BASIC`. No separate xrun invocation needed.
- **Standalone `xrun`** (for top-level integration): when you want to simulate the post-HLS Verilog RTL at the chip level, or run a non-HLS testbench, `xrun -access +rwc <files>` compiles + elaborates + sims in one shot. The `-access +rwc` flag makes signals probeable in SimVision.

For v0.1, Stratus-driven `csim` is enough. `lambda-xrun` and standalone xrun integration land in v0.2 when integration testbenches arrive.

### Genus + Innovus — the synthesis/PnR chain after HLS

After Stratus emits RTL, the chip-quality flow is:

```
src/blocks/<block>/*.cpp                       HLS source (in git)
        │
        ▼  (lambda-stratus mate batch BASIC)
$LAMBDA_WORK/<block>/stratus/<CFG>/<b>.v       Stratus-emitted Verilog RTL
        │
        ▼  (lambda-genus mate batch synth)
$LAMBDA_WORK/<block>/release/<b>.mapped.v      published by lambda_publish_release
        │
        ▼  (lambda-innovus mate batch route — flow content gated on PDK)
$LAMBDA_WORK/<block>/release/<b>.routed.{def,v,gds}
```

Each step has its own Tcl: `genus/synth.tcl`, `innovus/{init,floorplan,place,cts,route,signoff}.tcl` (the Innovus Foundation Flow convention). The launcher framework + run-area architecture landed in v0.4 (Innovus GUI chamber-confirmed live 2026-06-06 on `ip-10-2-6-68`); the real *flow content* is deferred to v0.5 because it needs a readable PDK. See "Filesystem & run-area architecture" above for why every output path roots at `$LAMBDA_WORK` (= `~/work/lambda`) and goes through `release/` for cross-stage handoff.

### Verified Innovus 21.18 Stylus Common UI invocation

Ground truth for the v0.4 pin `innovus/211/21.18.000` (= 21.18, the released family that matches `genus/211/21.18.000` — see Chamber execution model §3 above for why we don't default to the catalog newest `innovus/251`/25.14). Stylus syntax and flags also apply to 25.1 if you override the pin; verified against the *Innovus Stylus Common UI User Guide* + *Stylus Text Command Reference* (web, 2026-06-06) plus a live `module show innovus/251` (to confirm 251 defaults to 25.14, hence the pin choice) AND a live Stylus GUI launch under `module load innovus/211/21.18.000` on compute node `ip-10-2-6-68` (2026-06-06; license `invs` checked out clean). The `lambda-innovus` / `innovus-here` launchers bake these in:

```
innovus -stylus                 # enable Stylus Common UI (interactive REPL + GUI)
innovus -stylus -no_gui         # text REPL, no GUI
innovus -stylus -no_gui -files <flow.tcl> -log <log>   # headless batch
gui_show  /  gui_hide           # show/hide GUI in Common UI (legacy UI used `win`)
```

Confidence ladder (this matters — it's why the launcher is shaped the way it is):

1. **High / verified:** `-stylus`, `-no_gui`, `-log`, `gui_show`. The `gui` and `shell` subcommands use *only* these, so they cannot fail on unverified syntax.
2. **Medium / best-confirmed-not-tested:** `-files` as the Common UI script-source flag. Used *only* by the `batch` subcommand. **Fallback if a `batch` run rejects `-files` on 25.1:** `lambda-innovus <block> shell`, then `source <flow.tcl>` at the prompt, and pin the correct flag in `innovus-here`.

**`innovus` is a console REPL, not a pure GUI app** (the key difference from `stratus_ide`). So `lambda-innovus` runs Innovus in the **foreground**, inheriting your ETX terminal — it does NOT `gui_detach`/`nohup` it the way `stratus-gui` does, because that would leave no prompt to type `gui_show` into.

**PDK reality (load-bearing):** there is **no TSMC N16FFC PDK on the chamber** — `/process/hosted` has only `gpdk` (incl. `advgpdk` = `cds_ff_mpt`, the only FinFET-class vehicle) and `skywater`. So a real `init_design` against the target process is blocked on PDK *delivery* (admin-gated via `/process/hosted/xfer/incoming/`, TSMC University FinFET NDA), not on a "broken module." A flow against `advgpdk` is the de-risking path available *now*. See [chamber-sync-setup.md](chamber-sync-setup.md) and the chamber scope in `STATUS.md`.

---

## How to use it day-to-day

### First-time install (run once per teammate per chamber)

```bash
# 1. Get the latest repo on the chamber
sync-promote

# 2. Install launchers into ~/bin/, provision ~/work/lambda/{logs,inputs},
#    and write the work-root Makefile stub (idempotent — safe to re-run).
bash ~/architecture/tools/install.sh

# 3. Verify — autofs-aware, node-class-aware probe.
#    Run from a COMPUTE node (qsh -q normal.q -now n -V); the login node carries
#    only Virtuoso + vManager and will FAIL most tool probes by design.
chamber-diagnose
lambda-diagnose
```

If `chamber-diagnose` reports any `[FAIL]`, fix those before launching tools. The most common cause on a fresh setup is being on the login node — the probe will explicitly say so. The next most common is `$DISPLAY` unset (X11 forwarding broken) — fix at the SSH layer with `ssh -X` or `-Y`.

### Daily flow — HLS one block

```bash
# Drop into a compute node (interactive xterm on the chamber)
qsh -q normal.q -now n -V

# Verify the block has a project file
lambda-stratus mate diagnose

# Open the IDE
lambda-stratus mate gui

# Edit source in your editor of choice, then from the Stratus Tcl console:
#     cynth BASIC      # run HLS
#     csim BASIC       # run simulation (when TB sources are listed)

# Or run headless from another terminal
lambda-stratus mate batch BASIC

# Tail the latest batch log
lambda-stratus mate report BASIC

# Clean up build artifacts before re-running
lambda-stratus mate clean
```

### Daily flow — generic (any project, any directory)

```bash
# Open Stratus on whatever project.tcl is in the current dir
cd /path/to/any/hls-project/
stratus-gui                          # auto-detects ./project.tcl or ./stratus/project.tcl
stratus-gui some/other/project.tcl   # explicit path

# Headless equivalent
stratus-batch BASIC
stratus-batch BASIC some/other/project.tcl
```

The generic launchers know nothing about Lambda; they just take you to a Stratus IDE with the project loaded. Use them when working in a different project tree.

---

## Adding a new tool to Lambda (the pattern)

Say MatE HLS work has stabilized and you want a `lambda-xrun` for top-level integration testbenches. The pattern:

1. **Write the generic launcher first.** `tools/bin/xrun-here` knows how to load Xcelium and run `xrun -access +rwc <files>` with sensible defaults. No Lambda-specific knowledge.
2. **Write the Lambda wrapper second.** `tools/bin/lambda-xrun <block> <subcmd>` resolves `<block>` to `src/blocks/<block>/tb/run.tcl` (or files list) and delegates to `xrun-here`. ~40 lines.
3. **Document the per-block file convention.** Pick whether the TB runs from `src/blocks/<block>/tb/` (per-block) or `src/integration/<scope>/tb/` (chip-level integration). Update this file's repo layout section.
4. **Verify.** `bash -n tools/bin/lambda-xrun` syntax-checks; `lambda-xrun <block> diagnose` smoke-tests.

Same pattern for `lambda-genus`, `lambda-innovus`, `lambda-virtuoso` when v0.5 unblocks.

---

## Extrapolating to a new project

When the team starts a second chip / test block / sub-project, follow this recipe to inherit the generic layer.

### Option 1: Project is a sibling repo, not a fork

For an independent project (e.g., `LonghornSilicon/lpddr-phy-test`):

1. **Clone the generic scripts into the new repo.** Just `cp ~/architecture/tools/bin/{stratus-gui,stratus-batch,chamber-diagnose} <new-repo>/tools/bin/` plus `cp ~/architecture/tools/lib/* <new-repo>/tools/lib/`. The generic layer has zero Lambda dependencies — `grep -i lambda tools/bin/{stratus-gui,stratus-batch,chamber-diagnose}` confirms.
2. **Rename `lambda-env.sh` per the project.** Inside the new repo, rename to `<proj>-env.sh` and change `LAMBDA_ROOT`, `LAMBDA_SCRATCH`, etc. to `<PROJ>_ROOT` etc. Adjust the source paths in the generic scripts to match.
3. **Write the project-scoped wrappers.** A `<proj>-stratus` that resolves `<proj>-stratus <block> gui` against the new project's per-block structure. Pattern-copy `lambda-stratus`.
4. **Write a `tools/install.sh`** that symlinks the new bin/ into `~/bin/`. Conflicts with Lambda's `stratus-gui` etc. won't happen because they're identical scripts; conflicts in `<proj>-stratus` vs `lambda-stratus` are by design.

### Option 2: Project lives inside this repo

For a sub-project (e.g., `src/integration/`):

1. **Reuse the existing generic layer.** No new scripts needed.
2. **Author `src/integration/<scope>/{stratus,xcelium}/...` per-block Tcl files** following the same convention.
3. **Optionally add a thin `lambda-integration` script** that resolves a scope name to the right path; or just use the generic `stratus-gui`/`stratus-batch` directly with explicit project file paths.

### When to split out a separate `chamber-tools` repo

Today: don't. Lambda is the only project, and the generic scripts have no Lambda dependencies, so dragging them along with the Lambda repo costs nothing.

Trigger to split: **the second project lands.** At that point, factor `tools/bin/{stratus-gui,stratus-batch,chamber-diagnose}` and `tools/lib/*` out into `~/chamber-tools/`, set up its own sync-promote (or just `git clone` directly on the chamber, since the chamber has SFTP access to bundles), and update both Lambda and the second project to source from `~/chamber-tools/lib/*-env.sh`.

---

## Phasing

| Version | Scope | Status |
|---|---|---|
| **v0.1** (2026-05-17, commits `c6aa57d` → `7a5034f`) | `lambda-env.sh`, `lambda-detach.sh`, `stratus-{gui,batch}`, `chamber-diagnose`, `lambda-{stratus,diagnose}`, `install.sh`, stub `src/blocks/mate/stratus/project.tcl` | **PASSED.** Smoke test on `ae03ut01` (utility) + compute node 2026-05-17: `lambda-stratus mate gui` opens IDE cleanly on stub project. |
| **v0.3** (2026-06-06) | `innovus-here` + `lambda-innovus` (Stylus Common UI: `gui`/`shell`/`batch`/`diagnose`/`clean`), root `Makefile` flow wrapper, stub `src/blocks/mate/innovus/setup.tcl`, initial module pins (`innovus/251`, `xcelium/2109`) | **CHAMBER-CONFIRMED LIVE 2026-06-06.** Innovus Stylus GUI launched on compute node `ip-10-2-6-68`, license `invs` checked out clean. Initial pins were wrong (login-node debug confused autofs with "not installed"; v0.4 corrects them). |
| **v0.4** (2026-06-06) | `tools/lib/lambda-run.sh` (shared `lambda_require_tool`/`lambda_rundir`/`lambda_publish_release`), new launchers `genus-here`+`lambda-genus`, `xrun-here`+`lambda-xcelium`, `verisium-here`+`lambda-verisium`; Genus synth stub `src/blocks/mate/genus/synth.tcl`; CORRECTED module pins to confirmed-installed three-level matched family (`stratus/2201/22.01.009`, `genus/211/21.18.000`, `innovus/211/21.18.000`, `xcelium/2403/24.03.005`); **run-area relocation from `~/architecture/build/` → `~/work/lambda/`** (`$LAMBDA_WORK` home-backed; `LAMBDA_BUILD` aliased for back-compat; `src/blocks/mate/stratus/project.tcl` reads `$::env(LAMBDA_BUILD)` so Tcl follows bash); release/ handoff contract + MANIFEST; `chamber-diagnose` switched to autofs-aware load-then-test + node-type detection; README/handoff Calibre→Pegasus + PrimeTime→Tempus/SSV; this docs section. | **AUTHORED, FIRST-RUN GATE PENDING.** Interactive paths use only verified flags + correct pins. Two unverified items isolated with named fallbacks: (a) `verisium` binary name → falls back to `simvision` (ships in `XCELIUM2403`); (b) `xcelium/2403` may need pin-bump on other nodes (per-user override in `~/.longhorn/lambda.env`). |
| **v0.2** (when MatE HLS source lands) | license preflight wired into all launchers via a new `tools/lib/lambda-license.sh`, optional `--wait` queue-mode | Gated on MatE HLS C++ source committed. |
| **v0.5** (when a real PDK is readable from ETX) | `lambda-pegasus` (DRC/LVS), `lambda-tempus` (STA via SSV), `lambda-quantus`, `lambda-voltus`, `lambda-virtuoso`; a real `init_design`→`route`→`signoff` flow replacing the `setup.tcl` + `synth.tcl` stubs | **Gated on PDK, not on tools.** The tools (`pegasus/232`, `ssv/251`, plus Genus/Innovus/Xcelium from v0.4) are present on compute nodes. What's missing is the PDK: `/process/hosted` has only `gpdk` + `skywater` — **no TSMC N16FFC**. `advgpdk` (the installed `cds_ff_mpt`) is the only FinFET-class vehicle and is usable for flow bring-up; the real-process flow waits on PDK delivery via `/process/hosted/xfer/incoming/` (admin-gated, TSMC University FinFET NDA). |

---

## Lessons learned from v0.1 chamber bring-up

Eight issues hit during the iterative chamber smoke test. Documented because the next teammate (Richard, Chaithu) or the next chamber will likely hit the same ones, and because the patterns generalize to any project's launcher framework.

| # | Symptom | Root cause | Resolution |
|---|---|---|---|
| 1 | `lambda-diagnose: line 37: LAMBDA_ROOT: unbound variable` | `SCRIPT_DIR` resolved to `~/bin/` (the symlink dir) so `$SCRIPT_DIR/../lib/` pointed to `~/lib/` which doesn't exist. Source failure silently propagated to an unbound variable later. | Symlink-chain resolution in each launcher: `while [[ -L "$_src" ]]; do ...; done`. Source errors now fatal with a clear hint. |
| 2 | `[FAIL] module command not in this shell` from `chamber-diagnose` | `chamber-diagnose` is a bash subprocess; csh's `module` function doesn't propagate across shells. | `chamber-diagnose` also bootstraps `module` via `$MODULESHOME/init/bash` inline. |
| 3 | Static module-init fallback list didn't match anything | Chamber uses Env Modules v3.2.6a at `/apps/modules-v3.2.6a-64bit/Modules/init/bash`; the version-numbered dir wasn't in my list. | `lambda-env.sh` now prefers `${MODULESHOME}/init/bash` whenever `MODULESHOME` is exported (it is, on every Env-Modules chamber). Static list kept as belt-and-suspenders. |
| 4 | `/rscratch/$USER/lambda/logs/...: No such file or directory` on compute node | `/rscratch/$USER/` provisioned on utility node but NOT on compute nodes; user can't `mkdir` there. | Two layers of defense: `lambda-env.sh` falls back `LAMBDA_SCRATCH` to `/tmp/<user>-lambda` if `/rscratch` isn't writable; `gui_detach()` also falls back per-log-file. |
| 5 | `Unknown option -prj` in `stratus_ide` | Wrong flag name. Correct is `-project`, confirmed via help-text inspection. | `stratus-gui` uses `-project` now. |
| 6 | `define_hls_config: '-DCLOCK_PERIOD=1.0' is not a legal name for an hls_config` | Stratus parses unrecognized args as additional config names, not as macro defines. | Documented canonical syntax: `-DMACRO=val` goes inside the args list AFTER `<module> <config>`, never as a config name. |
| 7 | `wrong # args: should be "define_hls_config moduleSpec ccName args"` | `define_hls_config` requires module-name as first arg, then config name. Calling with just config name (no module) errors. | Stub `project.tcl` strips all `define_hls_*` commands until real HLS source lands (no source → no module → no config). Verified canonical syntax documented in the stub's comments. |
| 8 | `file size increased during transfer` from `lftp put` | Benign lftp warning when source file size is racy at SFTP-protocol stat-vs-transfer time. | Ignored — the file is uploaded correctly; subsequent `chmod` succeeds. |

## Open items and known limitations

| Item | Status | Resolution path |
|---|---|---|
| PDK module `projects/wfddemo/hdsdemo_sky130` is broken | Open | Tracked via the Cadence support case in [chamber-sync-setup.md](chamber-sync-setup.md). v0.5 launchers (`lambda-genus`, `lambda-innovus`) land once a TSMC N16FFC project module is available. |
| `/rscratch/$USER/` not provisioned on compute nodes | Worked around | Framework falls back to `/tmp/<user>-lambda/`. Worth filing a Cadence support case ("/rscratch/$USER not provisioned on compute nodes — utility node has it, compute doesn't") for proper fix; not blocking. |
| License feature names not yet verified | Open | Run `lmstat -a -c $CDS_LIC_FILE \| head -100` on the chamber once; pin actual feature names in `tools/lib/lambda-license.sh` when v0.2 license preflight lands. |
| Module init path varies by chamber | Resolved | `lambda-env.sh` auto-detects via `$MODULESHOME/init/bash`. Per-user override via `LAMBDA_MODULE_INIT` in `~/.longhorn/lambda.env` for non-standard chambers. |
| Only `mate` block has a stub `project.tcl` so far | Open | Other six blocks' READMEs reference `stratus/project.tcl` (the convention is set). Each block gets its real `project.tcl` when HLS source for that block begins. Follow `src/blocks/mate/stratus/project.tcl` and the canonical syntax under "Verified Stratus 22.01.009 Tcl syntax" above. |

## Verified versions (chamber — login + compute classes; debug session 2026-06-06)

Login class confirmed on `ae03ut01`; compute class confirmed on `ip-10-2-6-68` and `ip-10-2-6-30`. The chamber is an AWS-backed Cadence hosted environment; `/apps/<TOOL>` is autofs (mounts on `module load` + PATH touch — see Chamber execution model §1).

| Component | Version / path |
|---|---|
| OS | RHEL 7 (Linux 3.10.0-693.el7.x86_64) |
| Login shell | `/bin/csh` |
| Modules system | Environment Modules v3.2.6a at `/apps/modules-v3.2.6a-64bit/Modules` |
| `MODULEPATH` | `/home/cm_admin/modules/Linux/modulefiles` |
| Stratus HLS | `stratus/2201/22.01.009` → `/apps/STRATUS2201/22.01.009/` |
| Genus | `genus/211/21.18.000` → `/apps/GENUS211/21.18.000/` |
| Innovus (Stylus) | `innovus/211/21.18.000` → `/apps/INNOVUS211/21.18.000/` (live-launched 2026-06-06) |
| Xcelium | `xcelium/2403/24.03.005` → `/apps/XCELIUM2403/24.03.005/` (bundles `simvision`) |
| Verisium Debug | `verisiumdebug/2403/24.03.001` (catalog; first-run gate) |
| Pegasus (DRC/LVS) | `pegasus/232/23.24.000` (compute-node catalog) |
| SSV (Tempus/Voltus/Quantus) | `ssv/251/25.12.000` (signoff — deferred) |
| Storage tiers | `~/architecture` (git mirror, RO) · `~/work/lambda` (run area, home/NFS) · `/tmp/$USER-lambda` (ephemeral) · `/projects/<group>` (not provisioned for this team) · `/rscratch/$USER` (not provisioned) |
| Compute submission | `qsh -q normal.q -now n -V` (X11-forwarded interactive) |

---

## Directory dependencies and log/run dataflow

Where every launcher writes, where it reads, how data crosses tool boundaries, and what falls back to what when a write target is unavailable. This is the operational map — read it once, then refer back during postmortems.

### Three writes per run

Every batch launcher emits **three classes of artifact**, in three locations:

| Class | Default location | Lifetime | Who reads it |
|---|---|---|---|
| **Run-dir artifacts** (Cadence-native logs, DB, reports, outputs/) | `$LAMBDA_WORK/<block>/<tool>/<run-id>/` | Until `lambda-<tool> <block> clean` | Tool itself; debugging; next stage (via release/) |
| **Flat-list log** (one line per launch, easy to tail) | `$LAMBDA_LOGS/<tool>.<block>.<mode>[.<cfg>].<UTC-ts>.log` | Until log rotation (v0.5.1) | `*-report` subcommand; cross-block grep |
| **Release artifact + manifest** (cross-stage handoff) | `$LAMBDA_WORK/<block>/release/<artifact>` + `release/MANIFEST` | Overwritten on next successful publish; manifest is append-only | The *next* tool in the flow — never the producer |

The duplication is intentional. Run-dir logs are colocated with the artifacts the tool emitted, so when you `cd` into `mate/innovus/20260606-100530/` you have everything. The flat-list logs are the cross-block tail target — `tail -f $LAMBDA_LOGS/*.log` shows every run from every tool. The release artifacts are the **only** files the next stage may read from.

### Per-tool dependency map

`PROJ` = `$LAMBDA_ROOT` (the git mirror, RO). `WORK` = `$LAMBDA_WORK` (= `~/work/lambda` by default). `LOGS` = `$LAMBDA_LOGS` (= `$WORK/logs`).

```
                      READS                                            WRITES
┌─────────────────────────────────────────────┐   ┌─────────────────────────────────────────────────────┐
│ lambda-stratus <b> {gui|batch <CFG>}        │   │ run dir: WORK/<b>/stratus/[<run-id>/|interactive/]  │
│   PROJ/src/blocks/<b>/stratus/project.tcl   │ → │   <run-id>/<CFG>/<b>.v, bdw_work/, scverify_work/   │
│   (Tcl reads $::env(LAMBDA_BUILD)→WORK)     │   │   <run-id>/STATUS  (PASS|FAIL + UTC + rc; batch)    │
│                                             │   │ log:     LOGS/stratus.<b>.<mode>[.<CFG>].<ts>.log   │
│                                             │   │ release: WORK/<b>/release/<b>.hls.v   (batch, rc=0) │
│                                             │   │ manifest: WORK/<b>/release/MANIFEST  (append)       │
└─────────────────────────────────────────────┘   └─────────────────────────────────────────────────────┘
                                                         │
                                                         ▼ (read by next stage from release/)
┌─────────────────────────────────────────────┐   ┌─────────────────────────────────────────────────────┐
│ lambda-genus <b> {gui|shell|batch <flow>}   │   │ run dir: WORK/<b>/genus/[<run-id>/|interactive/]    │
│   PROJ/src/blocks/<b>/genus/<flow>.tcl      │ → │   outputs/<b>.mapped.v, reports/{timing,area,pwr}   │
│   WORK/<b>/release/<b>.hls.v   (consumer)   │   │   genus.log, genus.cmd                              │
│                                             │   │ log:     LOGS/genus.<b>.<mode>.<ts>.log             │
│                                             │   │ release: WORK/<b>/release/<b>.mapped.v   (on rc=0)  │
│                                             │   │ manifest: WORK/<b>/release/MANIFEST  (append)       │
└─────────────────────────────────────────────┘   └─────────────────────────────────────────────────────┘
                                                         │
                                                         ▼
┌─────────────────────────────────────────────┐   ┌─────────────────────────────────────────────────────┐
│ lambda-innovus <b> {gui|shell|batch <flow>} │   │ run dir: WORK/<b>/innovus/[<run-id>/|interactive/]  │
│   PROJ/src/blocks/<b>/innovus/<flow>.tcl    │ → │   outputs/<b>.routed.{def,v,gds}                    │
│   WORK/<b>/release/<b>.mapped.v             │   │   innovus.log, innovus.cmd, db/                     │
│   (exported as $LAMBDA_NETLIST)             │   │ log:     LOGS/innovus.<b>.<mode>.<ts>.log           │
│                                             │   │ release: WORK/<b>/release/<b>.routed.{def,v,gds}    │
└─────────────────────────────────────────────┘   └─────────────────────────────────────────────────────┘
                                                         │
                                                         ▼
┌─────────────────────────────────────────────┐   ┌─────────────────────────────────────────────────────┐
│ lambda-pegasus <b>  [v0.5 — PDK-gated]      │   │ run dir: WORK/<b>/pegasus/<run-id>/                 │
│   WORK/<b>/release/<b>.routed.{def,gds}     │ → │   <b>.drc.rpt, <b>.lvs.rpt                          │
│                                             │   │ release: WORK/<b>/release/<b>.drc.rpt               │
└─────────────────────────────────────────────┘   └─────────────────────────────────────────────────────┘

                         Verification path (parallel to synth/PnR):

┌─────────────────────────────────────────────┐   ┌─────────────────────────────────────────────────────┐
│ lambda-xcelium <b> {sim|gui|batch} <args>   │   │ run dir: WORK/<b>/xcelium/<run-id>/                 │
│   PROJ/src/blocks/<b>/tb/{*.cpp,xrun.args}  │ → │   xcelium.d/, xrun.log, xrun.history, xrun.key      │
│   xrun args supply: RTL sources, top, +UVM* │   │   waves.shm/    (when -access +rwc)                 │
│                                             │   │ log:     LOGS/xrun.<b>.<mode>.<ts>.log              │
│                                             │   │ latest:  WORK/<b>/xcelium/latest -> <run-id>        │
└─────────────────────────────────────────────┘   └─────────────────────────────────────────────────────┘
                                                         │
                                                         ▼ (read by verisium via latest symlink)
┌─────────────────────────────────────────────┐   ┌─────────────────────────────────────────────────────┐
│ lambda-verisium <b> [<waves.shm>]           │   │ log:  LOGS/verisium.<basename>.<ts>.log             │
│   WORK/<b>/xcelium/latest/waves.shm         │ → │ GUI session (no file artifacts)                     │
└─────────────────────────────────────────────┘   └─────────────────────────────────────────────────────┘
```

### Resolution rules — the order each launcher tries

A launcher fails over through a defined ladder before giving up. Know the ladder so postmortems are mechanical, not exploratory.

**Project / flow file resolution** (`lambda-genus mate batch synth`):

1. Caller passed an absolute path or `./relative` path → if it's a file, use it.
2. Resolve against the project-scoped flow dir: `$LAMBDA_ROOT/src/blocks/<block>/<tool>/<arg>` → if file, use it.
3. Same, with `.tcl` appended: `…/<arg>.tcl` → if file, use it.
4. Otherwise: fatal error naming all three paths tried.

Same shape in `lambda-stratus`, `lambda-genus`, `lambda-innovus`, `lambda-xcelium`.

**Run-dir selection** (`lambda_rundir`, `lambda-run.sh:98-137`):

| Mode | Path | Re-use? | `latest` symlink updated? |
|---|---|---|---|
| `gui` | `$LAMBDA_WORK/<b>/<tool>/interactive/` | yes (stable dir) | no |
| `shell` | `$LAMBDA_WORK/<b>/<tool>/interactive/` | yes | no |
| `batch` | `$LAMBDA_WORK/<b>/<tool>/<UTC-runid>/` | never — new dir per invocation | yes (atomic-ish: `ln -sfn <id> .latest.$$; mv -f .latest.$$ latest`) |

**Storage fallback ladder** (`lambda-env.sh:141-153`, `lambda-detach.sh:54-61`, each launcher's log-dir guard):

1. Try `$LAMBDA_WORK` (= `~/work/lambda`, NFS home). If writable → use it.
2. Fall back to `$LAMBDA_FAST` (= `/tmp/$USER-lambda`, node-local, wiped on reboot). Warn to stderr.
3. For per-launch log files specifically: if `$LAMBDA_LOGS` not writable, fall back to `/tmp/<basename>`. Warn.
4. There is no further fallback. If even `/tmp` is unwritable, the launcher fails with a clear error.

**Module fallback ladder** (`lambda-env.sh:92-138`):

1. If `LAMBDA_MODULE_INIT` is set in `~/.longhorn/lambda.env` → source it. (Per-user override; always wins.)
2. Else if `$MODULESHOME/init/bash` exists (the standard Environment Modules layout) → source it. (Verified on `ae03ut01`.)
3. Else iterate a static list of 16 known module-init paths covering Env Modules, Lmod, and chamber-specific install layouts. Use the first that exists.
4. If none → `module` is undefined, every `lambda_require_tool` call fails with the canonical chamber-diagnose hint.

**Verisium tool fallback** (`verisium-here:86-118` — only fallback for an *application* binary, not a path/dir):

1. Try `$VERISIUM_MODULE` (`verisiumdebug/2403/24.03.001`) → load + `command -v verisium` → exec `verisium debug -input <waves>`.
2. On any failure, fall through. Print the captured primary error. Try `$XCELIUM_MODULE` → load + `command -v simvision` → exec `simvision -waves <waves>`. (SimVision ships inside `XCELIUM2403`, decade-stable.)
3. If both fail → fatal error, hint to `lambda-diagnose`.

### Why every tool publishes to `release/` instead of letting the next tool read sibling dirs

The release/ contract decouples "the messy run that emitted this artifact" from "the input the next stage consumes." Three load-bearing properties:

1. **Cross-run stability.** Genus runs in `genus/20260606-100530/` and writes `outputs/mate.mapped.v`. Innovus, run an hour later, doesn't have to know that exact run-id — it reads `release/mate.mapped.v`, which is whatever the *most recent successful* Genus run published.
2. **Failure isolation.** A crashed Genus run still has an `outputs/` subdir with whatever it managed to write before SEGV. Downstream reads from `release/` skip it entirely — only successful runs publish.
3. **Audit trail.** `release/MANIFEST` is append-only: every line records `<UTC>  <tool>  <artifact>  <run-id>  sha=<git>`. You can answer "which Genus run produced the netlist that Innovus is currently reading?" by `tail -1 release/MANIFEST` filtered on tool. Without a manifest, this is git archeology.

The trade is that **the consumer reads from `release/`, never from a sibling run dir.** As of v0.4.1 this is honored for **both** Stratus → Genus (via `release/<b>.hls.v`) and Genus → Innovus (via `release/<b>.mapped.v`). The remaining edge — Innovus → Pegasus via `release/<b>.routed.{def,gds}` — lands with the v0.5 PDK-gated launchers and uses the same `lambda_publish_release` helper, so no new pattern is needed.

### Putting it together — one decode through the dataflow

The full back-end pipe for the MatE block, once HLS source + PDK + flow code land:

```
edit src/blocks/mate/{pe.cpp,mate.cpp,tb/main.cpp}                                  (in git, $LAMBDA_ROOT)
        │
        ▼  lambda-stratus mate batch BASIC
WORK/mate/stratus/<run-id>/BASIC/mate.v                                             (Stratus RTL)
WORK/mate/stratus/<run-id>/STATUS                                                   (PASS|FAIL marker)
WORK/mate/release/mate.hls.v                          [published, MANIFEST appended]
LOGS/stratus.mate.batch.BASIC.<ts>.log
        │
        ▼  lambda-genus mate batch synth
WORK/mate/genus/<run-id>/outputs/mate.mapped.v                                      (Genus netlist)
WORK/mate/genus/<run-id>/reports/{timing,area,power}.rpt
WORK/mate/release/mate.mapped.v                       [published, MANIFEST appended]
LOGS/genus.mate.batch.<ts>.log
        │
        ▼  lambda-innovus mate batch route       (v0.5; needs PDK)
WORK/mate/innovus/<run-id>/outputs/mate.routed.{def,v,gds}
WORK/mate/release/mate.routed.{def,v,gds}             [published, MANIFEST appended]
LOGS/innovus.mate.batch.<ts>.log
        │
        ▼  lambda-pegasus mate batch drc         (v0.5; needs PDK + runset)
WORK/mate/pegasus/<run-id>/mate.drc.rpt
WORK/mate/release/mate.drc.rpt                        [published]
LOGS/pegasus.mate.batch.<ts>.log

Verification, parallel:
        ▼  lambda-xcelium mate sim -access +rwc  (reads tb/* + release/mate.mapped.v as DUT)
WORK/mate/xcelium/<run-id>/{xcelium.d/,xrun.log,waves.shm/}
WORK/mate/xcelium/latest -> <run-id>
LOGS/xrun.mate.sim.<ts>.log
        │
        ▼  lambda-verisium mate                  (follows xcelium/latest → waves.shm)
LOGS/verisium.waves.<ts>.log     (GUI session; no file artifact)
```

A teammate dropped into `~/work/lambda/` at any point can answer "what's the current best mate.mapped.v?" with `cat mate/release/MANIFEST | grep mate.mapped.v | tail -1` and find both the artifact and the run that produced it. That's the whole point of the contract.

### Reading the run-area at a glance: three orthogonal signals

A teammate dropping into someone else's `~/work/lambda/` can answer three different questions without reading any tool log, by consulting three different filesystem artifacts:

| Question | Where to look | Updated by |
|---|---|---|
| "Which run was the most recent for this block × tool?" | `<block>/<tool>/latest` symlink | `lambda_rundir batch` at mint time |
| "Did that specific run pass or fail?" | `<block>/<tool>/<run-id>/STATUS` file (`PASS \| FAIL` + UTC + rc) | `lambda_finalize_rundir` at exit |
| "Which run produced the artifact the next stage is currently consuming?" | `<block>/release/MANIFEST` tail entry per artifact | `lambda_publish_release` on rc=0 |

The three signals are independent on purpose. `latest` follows invocations, not success — so `lambda-verisium <block>` reaches a *crashed* run's `waves.shm/` for debug. `STATUS` answers pass/fail of that specific run without grepping the log. `MANIFEST` tracks the cross-stage handoff: which run-id stamped the artifact the consumer reads.

### Pitfall: what's *not* in this map yet

One edge still uses a placeholder, gated on tooling not yet present:

- **Innovus → Pegasus** publishes `<b>.routed.{def,v,gds}` to `release/` as of v0.4 (`lambda-innovus batch` calls `lambda_publish_release`), but `lambda-pegasus` itself doesn't exist — it lands in v0.5 along with Tempus/Quantus/Voltus once a readable TSMC N16FFC PDK is delivered (see "Phasing" v0.5 row). The release-side of this edge is wired; the consumer-side is gated on PDK delivery, not on tool framework work.

Gaps #1 (shared Stratus `<CFG>/` race), #2 (no STATUS marker), and #4 (Stratus → Genus broken release edge) from the v0.4 audit were closed in v0.4.1 — Stratus now mints per-invocation `<run-id>/` dirs, every batch launcher writes a STATUS marker via `lambda_finalize_rundir`, and `lambda-stratus batch` publishes `<b>.hls.v` to `release/` so the Genus stub reads from the contract path. See the dependency map above for the post-v0.4.1 state.

---

## Reference: file-by-file

| File | Type | Lines | Purpose |
|---|---|---|---|
| `tools/install.sh` | installer | ~120 | **v0.4 expanded.** Idempotent: symlinks `tools/bin/*` into `~/bin/` (picks up new launchers via glob); provisions `~/work/lambda/{logs,inputs}` (the home-backed run area); writes a 2-line stub `~/work/lambda/Makefile` (uses `?=` so user overrides win); runs `lambda-diagnose`. |
| `tools/lib/lambda-env.sh` | sourced | ~60 | Default paths, tool module pins, Lambda block list, module init bootstrap. Sources `~/.longhorn/lambda.env` if present (per-user override). |
| `tools/lib/lambda-detach.sh` | sourced | ~55 | `gui_detach <tag> <tool> <args...>`: nohup + log + PID file. Encapsulates the csh-vs-bash GUI backgrounding pattern. |
| `tools/bin/stratus-gui` | generic launcher | ~70 | Opens `stratus_ide -prj <file>` on a project.tcl in CWD or an explicit path. Module load + X11 check + detach. |
| `tools/bin/stratus-batch` | generic launcher | ~70 | Runs `stratus -batch <project> -do "cynth <config>; exit"` headless. Logs to scratch. |
| `tools/bin/chamber-diagnose` | generic probe | ~120 | Shell, X11, module system, tool availability, storage paths, license server, `~/bin/` PATH check. Read-only. |
| `tools/bin/lambda-stratus` | project wrapper | ~140 | Resolves `<block>` to its `stratus/project.tcl`; delegates to `stratus-gui` / `stratus-batch`. Adds `clean`, `report`, `diagnose` subcommands. |
| `tools/bin/lambda-diagnose` | project probe | ~70 | Runs `chamber-diagnose` then adds Lambda-specific checks: LAMBDA_ROOT, git HEAD, per-block project.tcl presence. |
| `tools/bin/innovus-here` | generic launcher | ~150 | **v0.3, v0.4 retrofit.** Foreground Innovus (Stylus) launcher: `gui`/`shell`/`batch`. Verified-flags-only on interactive; `-files` for batch. v0.4 uses `lambda_require_tool` from `lambda-run.sh`. |
| `tools/bin/lambda-innovus` | project wrapper | ~190 | **v0.3, v0.4 retrofit.** Resolves `<block>` to `$LAMBDA_WORK/<block>/innovus/` run dir + `src/blocks/<block>/innovus/` flow dir; uses `lambda_rundir` for interactive vs `<run-id>`/batch; on batch success publishes `<block>.routed.{def,v,gds}` to `release/` via `lambda_publish_release`. |
| `Makefile` (repo root) | flow wrapper | ~190 | **v0.3, v0.4 expanded.** Ergonomic + dependency-DAG layer. v0.4 adds `genus`/`genus-shell`/`genus-batch`, `sim`/`sim-gui`/`sim-batch`, `waves`/`waves-diag`, plus updated help and `$LAMBDA_WORK`-rooted FLOW DAG. |
| `src/blocks/mate/innovus/setup.tcl` | flow stub | ~70 | **v0.3.** Stub Stylus flow: documents the Foundation-flow skeleton; live body is pure-core Tcl. Exits in batch via `INNOVUS_BATCH`. |
| `tools/lib/lambda-run.sh` | sourced | ~150 | **v0.4.** Shared launcher helpers: `lambda_require_tool` (autofs/compute-node aware module-load + binary check, emits the LOGIN-vs-compute hint), `lambda_rundir` (interactive vs timestamped batch + `latest` symlink), `lambda_publish_release` (cross-stage handoff to `release/` + MANIFEST). |
| `tools/bin/genus-here` | generic launcher | ~125 | **v0.4.** Foreground Genus (Common UI is default; NO `-stylus`): `gui`/`shell`/`batch`. `batch` uses `-no_gui -files` + `GENUS_BATCH=1`. |
| `tools/bin/lambda-genus` | project wrapper | ~155 | **v0.4.** Resolves `<block>` to `$LAMBDA_WORK/<block>/genus/`; publishes `<block>.mapped.v` to `release/` on batch success. |
| `tools/bin/xrun-here` | generic launcher | ~115 | **v0.4.** Xcelium `xrun` driver: `sim` (headless), `gui` (SimVision live via `-gui`), `batch` (`xrun -f <args>`). Dumps `xcelium.d/`, `waves.shm/` in the run dir. |
| `tools/bin/lambda-xcelium` | project wrapper | ~170 | **v0.4.** Resolves `<block>` to `$LAMBDA_WORK/<block>/xcelium/`; `waves` subcommand jumps to `lambda-verisium` on the latest run's `waves.shm`. |
| `tools/bin/verisium-here` | generic launcher | ~100 | **v0.4.** Waveform-debug GUI: tries `verisium debug -input <waves>` first; falls back to `simvision -waves <waves>` (ships in `XCELIUM2403`, decade-stable). Documented confidence ladder. |
| `tools/bin/lambda-verisium` | project wrapper | ~105 | **v0.4.** `lambda-verisium <block>` opens the latest xcelium run's `waves.shm`; `<block> diagnose` shows runs found + primary/fallback pins. |
| `src/blocks/mate/genus/synth.tcl` | flow stub | ~75 | **v0.4.** Stub Common-UI synth flow mirroring `setup.tcl` style: pure-Tcl body, no PDK paths, exits via `GENUS_BATCH`. Documents the Common-UI synth skeleton (`read_hdl`/`elaborate`/`syn_generic`/`syn_map`/`write_hdl`). |
| `src/blocks/mate/stratus/project.tcl` | HLS project | ~75 | **v0.1, v0.4 fix.** Stub HLS project (no `define_hls_*` until source lands). v0.4 reads `$::env(LAMBDA_BUILD)` so Stratus follows the bash retier — without this, output silently kept writing into the repo mirror. |

Total: ~2200 lines across 20 files. Small, auditable, version-controlled.
