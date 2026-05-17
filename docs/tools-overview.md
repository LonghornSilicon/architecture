# Lambda Chamber Tooling Framework

**What this is:** the convention for launching Cadence tools (Stratus HLS, Xcelium, Genus, Innovus, Virtuoso) from a teammate's `~/bin/` on the chamber, against the Lambda repo or any future project. Read once; reuse forever.

**Companion docs:**
- [`chamber-sync-setup.md`](chamber-sync-setup.md) — how the repo gets onto the chamber in the first place (git bundles + `sync-promote`).
- [`../arch.yml`](../arch.yml) — what the chip actually is.
- Block READMEs at [`../src/blocks/<block>/README.md`](../src/blocks/) — per-block spec.

---

## TL;DR

```bash
# One-time setup (per teammate, on the chamber)
sync-promote                                       # pull latest main
bash ~/architecture/tools/install.sh               # symlinks tools/bin/* into ~/bin/

# Daily use (any block, any subcommand)
lambda-stratus mate gui                            # open IDE on MatE
lambda-stratus mate batch BASIC                    # headless cynth BASIC
lambda-stratus mate diagnose                       # what's wrong?
chamber-diagnose                                   # what's wrong with the chamber itself?
```

That's the whole interface. Everything below is justification, mental models, and extrapolation paths.

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
src/blocks/<block>/*.cpp           HLS source
        │
        ▼  (lambda-stratus mate batch BASIC)
build/<block>/stratus/BASIC/...    Stratus-emitted Verilog RTL
        │
        ▼  (lambda-genus mate batch — v0.5, gated on PDK case)
build/<block>/genus/...            Gate-level netlist
        │
        ▼  (lambda-innovus mate {init,place,cts,route,signoff})
build/<block>/innovus/...          DEF/GDS/SDF
```

Each step has its own Tcl: `genus/synth.tcl`, `innovus/{init,floorplan,place,cts,route,signoff}.tcl` (the Innovus Foundation Flow convention). These are deferred to v0.5 because they need the PDK module that is currently broken per [chamber-sync-setup.md](chamber-sync-setup.md) open items.

---

## How to use it day-to-day

### First-time install (run once per teammate per chamber)

```bash
# 1. Get the latest repo on the chamber
sync-promote

# 2. Install launchers into ~/bin/ and create scratch dir
bash ~/architecture/tools/install.sh

# 3. Verify
chamber-diagnose
lambda-diagnose
```

If `chamber-diagnose` reports any `[FAIL]`, fix those before launching tools. The most common failure is `$DISPLAY` not set (X11 forwarding broken); fix at the SSH layer with `ssh -X` or `-Y`.

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

| Version | Scope | Gates |
|---|---|---|
| **v0.1** (this commit) | `lambda-env.sh`, `lambda-detach.sh`, `stratus-{gui,batch}`, `chamber-diagnose`, `lambda-{stratus,diagnose}`, `install.sh`, stub `src/blocks/mate/stratus/project.tcl` | None. Smoke target: `lambda-stratus mate gui` opens an IDE with the stub. |
| **v0.2** (when MatE HLS source lands) | `xrun-here`, `lambda-xrun`, license preflight wired into all launchers via a new `tools/lib/lambda-license.sh`, optional `--wait` queue-mode | MatE HLS C++ source committed. |
| **v0.5** (when PDK case clears) | `genus-here`, `innovus-here`, `virtuoso-here`, plus `lambda-genus`, `lambda-innovus`, `lambda-virtuoso` | TSMC N16FFC project module available on chamber. |

---

## Open items and known limitations

| Item | Impact | Resolution path |
|---|---|---|
| PDK module `projects/wfddemo/hdsdemo_sky130` is broken | Genus / Innovus can't run end-to-end; Stratus HLS-only works because it doesn't need the tech library | Track via the open Cadence support case in [chamber-sync-setup.md](chamber-sync-setup.md). v0.5 launchers land once a TSMC N16FFC project module is available. |
| License feature names not yet verified | v0.2 license preflight (e.g., `lmstat ... | grep Stratus_HLS`) is uncertain | Run `lmstat -a -c $CDS_LIC_FILE | head -100` on the chamber once; pin actual feature names in `tools/lib/lambda-license.sh`. |
| Module init path varies by chamber config | `lambda-env.sh` tries `/etc/profile.d/modules.sh`, `/usr/share/Modules/init/bash`, etc. If none of these match the chamber's actual path, `module load` fails. | First time someone hits this, run `find / -name 'modules*' -path '*/init/*' 2>/dev/null`, add the path to `lambda-env.sh`'s loop. |
| Only `mate` block has a stub `project.tcl` so far | Other six blocks' READMEs reference `stratus.tcl` (singular) but no file exists | Will be created per-block as HLS work begins. Follow `src/blocks/mate/stratus/project.tcl` pattern. |

---

## Reference: file-by-file

| File | Type | Lines | Purpose |
|---|---|---|---|
| `tools/install.sh` | installer | ~80 | Idempotent: symlinks `tools/bin/*` into `~/bin/`, creates scratch dir, runs `lambda-diagnose`. |
| `tools/lib/lambda-env.sh` | sourced | ~60 | Default paths, tool module pins, Lambda block list, module init bootstrap. Sources `~/.longhorn/lambda.env` if present (per-user override). |
| `tools/lib/lambda-detach.sh` | sourced | ~55 | `gui_detach <tag> <tool> <args...>`: nohup + log + PID file. Encapsulates the csh-vs-bash GUI backgrounding pattern. |
| `tools/bin/stratus-gui` | generic launcher | ~70 | Opens `stratus_ide -prj <file>` on a project.tcl in CWD or an explicit path. Module load + X11 check + detach. |
| `tools/bin/stratus-batch` | generic launcher | ~70 | Runs `stratus -batch <project> -do "cynth <config>; exit"` headless. Logs to scratch. |
| `tools/bin/chamber-diagnose` | generic probe | ~120 | Shell, X11, module system, tool availability, storage paths, license server, `~/bin/` PATH check. Read-only. |
| `tools/bin/lambda-stratus` | project wrapper | ~140 | Resolves `<block>` to its `stratus/project.tcl`; delegates to `stratus-gui` / `stratus-batch`. Adds `clean`, `report`, `diagnose` subcommands. |
| `tools/bin/lambda-diagnose` | project probe | ~70 | Runs `chamber-diagnose` then adds Lambda-specific checks: LAMBDA_ROOT, git HEAD, per-block project.tcl presence. |

Total: ~660 lines across 8 files. Small, auditable, version-controlled.
