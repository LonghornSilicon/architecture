# ============================================================================
# Lambda — chamber flow Makefile
# ----------------------------------------------------------------------------
# Ergonomic top layer over the tools/bin/ launchers. RUN THIS ON THE CHAMBER,
# from an interactive ETX/X11 session, after `sync-promote` + tools/install.sh.
#
# Design: this Makefile is a THIN WRAPPER. It does not reimplement the chamber
# resilience (csh `module` bootstrap, /rscratch->/tmp fallback, X11 preflight,
# symlink resolution) — that lives in the bash launchers, which were smoke-
# tested over 8 bring-up iterations. Make adds two things on top:
#   1. muscle-memory targets (`make innovus BLOCK=mate`)
#   2. a real dependency DAG for the back-end flow (see "FLOW DAG" below), so
#      `make <stage>` rebuilds only what's stale once real RTL/PDK exist.
#
# Layering:   make  ->  lambda-stratus / lambda-innovus (bash)  ->  tool + .tcl
#
# Usage:
#   make help
#   make gui            BLOCK=mate         # Stratus HLS IDE
#   make hls            BLOCK=mate CFG=BASIC
#   make innovus        BLOCK=mate         # Innovus Stylus + GUI
#   make innovus-shell  BLOCK=mate         # Innovus Stylus text REPL
#   make genus          BLOCK=mate         # Genus Common UI + GUI
#   make sim            BLOCK=mate         # Xcelium xrun (headless)
#   make waves          BLOCK=mate         # Verisium / SimVision on latest waves
#   make diag                              # full chamber + Lambda probe
#
# Variables:
#   BLOCK       which Lambda block (mate kce vecu tiu msc lsu hif)
#   CFG         Stratus HLS config name (e.g. BASIC)
#   FLOW        Innovus/Genus batch flow name (default: setup / synth)
#   LAMBDA_WORK run/release root, defaults to ~/work/lambda (set by stub Makefile)
# ============================================================================

# ---- Knobs (override on the command line: `make hls BLOCK=kce CFG=FALLBACK`) -
BLOCK ?= mate
CFG   ?= BASIC
LAMBDA_WORK ?= $(HOME)/work/lambda
# v0.4.2 (M8): export so recipe children (the bash launchers) see the
# make-level value; an unexported make var never reaches the recipe's
# subprocess env, so launchers silently fell back to lambda-env.sh defaults.
export LAMBDA_WORK

# Launchers are on $PATH via tools/install.sh (~/bin symlinks). Fall back to the
# in-repo path so `make` works even before install.sh has run.
BIN          := $(HOME)/architecture/tools/bin
LAMBDA_STRAT := $(shell command -v lambda-stratus  2>/dev/null || echo $(BIN)/lambda-stratus)
LAMBDA_INNO  := $(shell command -v lambda-innovus  2>/dev/null || echo $(BIN)/lambda-innovus)
LAMBDA_GENUS := $(shell command -v lambda-genus    2>/dev/null || echo $(BIN)/lambda-genus)
LAMBDA_XCEL  := $(shell command -v lambda-xcelium  2>/dev/null || echo $(BIN)/lambda-xcelium)
LAMBDA_VERI  := $(shell command -v lambda-verisium 2>/dev/null || echo $(BIN)/lambda-verisium)
LAMBDA_DIAG  := $(shell command -v lambda-diagnose 2>/dev/null || echo $(BIN)/lambda-diagnose)

.DEFAULT_GOAL := help

# ---- Phony ergonomic targets (work today) ----------------------------------
.PHONY: help diag gui hls hls-report hls-clean innovus innovus-shell \
        innovus-batch innovus-diag innovus-clean \
        genus genus-shell genus-batch genus-diag genus-clean \
        sim sim-gui sim-batch sim-diag sim-clean waves waves-diag \
        clean

help:
	@echo "Lambda chamber flow — run from an ETX session on a COMPUTE node."
	@echo ""
	@echo "Variables:  BLOCK=$(BLOCK)   CFG=$(CFG)   LAMBDA_WORK=$(LAMBDA_WORK)"
	@echo "Blocks:     mate kce vecu tiu msc lsu hif"
	@echo ""
	@echo "Diagnostics:"
	@echo "  make diag                                full chamber + Lambda probe"
	@echo ""
	@echo "HLS (Stratus):"
	@echo "  make gui            BLOCK=$(BLOCK)               Stratus IDE"
	@echo "  make hls            BLOCK=$(BLOCK) CFG=$(CFG)      headless cynth"
	@echo "  make hls-report     BLOCK=$(BLOCK) CFG=$(CFG)      tail latest HLS log"
	@echo "  make hls-clean      BLOCK=$(BLOCK)               rm \$$LAMBDA_WORK/<b>/stratus"
	@echo ""
	@echo "Synthesis (Genus, Common UI):"
	@echo "  make genus          BLOCK=$(BLOCK)               Genus + GUI"
	@echo "  make genus-shell    BLOCK=$(BLOCK)               Genus text REPL"
	@echo "  make genus-batch    BLOCK=$(BLOCK) FLOW=synth     headless flow"
	@echo "  make genus-diag     BLOCK=$(BLOCK)               paths + module check"
	@echo "  make genus-clean    BLOCK=$(BLOCK)               rm \$$LAMBDA_WORK/<b>/genus"
	@echo ""
	@echo "Simulation (Xcelium xrun):"
	@echo "  make sim            BLOCK=$(BLOCK) <args...>     xrun headless"
	@echo "  make sim-gui        BLOCK=$(BLOCK) <args...>     xrun -gui (SimVision live)"
	@echo "  make sim-batch      BLOCK=$(BLOCK) ARGS=...      xrun -f <args-file>"
	@echo "  make sim-diag       BLOCK=$(BLOCK)"
	@echo "  make sim-clean      BLOCK=$(BLOCK)"
	@echo ""
	@echo "Waveform debug (Verisium / SimVision fallback):"
	@echo "  make waves          BLOCK=$(BLOCK)               open latest waves"
	@echo "  make waves-diag     BLOCK=$(BLOCK)"
	@echo ""
	@echo "Place & route (Innovus, Stylus Common UI):"
	@echo "  make innovus        BLOCK=$(BLOCK)               Innovus + GUI"
	@echo "  make innovus-shell  BLOCK=$(BLOCK)               Innovus text REPL"
	@echo "  make innovus-batch  BLOCK=$(BLOCK) FLOW=setup    headless flow"
	@echo "  make innovus-diag   BLOCK=$(BLOCK)               paths + module check"
	@echo "  make innovus-clean  BLOCK=$(BLOCK)               rm \$$LAMBDA_WORK/<b>/innovus"

diag:
	@$(LAMBDA_DIAG)

# --- HLS (Stratus) ---
gui:
	@$(LAMBDA_STRAT) $(BLOCK) gui
hls:
	@$(LAMBDA_STRAT) $(BLOCK) batch $(CFG)
hls-report:
	@$(LAMBDA_STRAT) $(BLOCK) report $(CFG)
hls-clean:
	@$(LAMBDA_STRAT) $(BLOCK) clean

# --- Synthesis (Genus, Common UI) ---
genus:
	@$(LAMBDA_GENUS) $(BLOCK) gui
genus-shell:
	@$(LAMBDA_GENUS) $(BLOCK) shell
genus-batch:
	@$(LAMBDA_GENUS) $(BLOCK) batch $(or $(FLOW),synth)
genus-diag:
	@$(LAMBDA_GENUS) $(BLOCK) diagnose
genus-clean:
	@$(LAMBDA_GENUS) $(BLOCK) clean

# --- Simulation (Xcelium xrun) ---
# Trailing ARGS forwarded raw — example: `make sim BLOCK=mate ARGS='-access +rwc tb/main.cpp'`
sim:
	@$(LAMBDA_XCEL) $(BLOCK) sim $(ARGS)
sim-gui:
	@$(LAMBDA_XCEL) $(BLOCK) gui $(ARGS)
sim-batch:
	@$(LAMBDA_XCEL) $(BLOCK) batch $(or $(ARGS),tb/xrun.args)
sim-diag:
	@$(LAMBDA_XCEL) $(BLOCK) diagnose
sim-clean:
	@$(LAMBDA_XCEL) $(BLOCK) clean

# --- Waveform debug (Verisium / SimVision) ---
waves:
	@$(LAMBDA_VERI) $(BLOCK)
waves-diag:
	@$(LAMBDA_VERI) $(BLOCK) diagnose

# --- Innovus (Stylus Common UI) ---
innovus:
	@$(LAMBDA_INNO) $(BLOCK) gui
innovus-shell:
	@$(LAMBDA_INNO) $(BLOCK) shell
innovus-batch:
	@$(LAMBDA_INNO) $(BLOCK) batch $(or $(FLOW),setup)
innovus-diag:
	@$(LAMBDA_INNO) $(BLOCK) diagnose
innovus-clean:
	@$(LAMBDA_INNO) $(BLOCK) clean

# v0.4.2 (m6): one summary confirmation instead of four sequential per-tool
# prompts (the launchers' clean subcommands each ask their own y/N — fine
# individually, tedious chained). Lists everything first, asks once, and
# refuses outright when stdin is not a tty (CI / piped invocation) rather
# than hanging on `read` or eating an EOF as "no".
clean:
	@if [ ! -t 0 ]; then \
		echo "ERROR: 'make clean' is interactive (single y/N confirm); refusing without a tty." >&2; \
		echo "Hint:  remove $(LAMBDA_WORK)/$(BLOCK)/{stratus,genus,xcelium,innovus} manually if scripting." >&2; \
		exit 1; \
	fi; \
	echo "make clean will remove (BLOCK=$(BLOCK)):"; \
	any=0; \
	for d in stratus genus xcelium innovus; do \
		t="$(LAMBDA_WORK)/$(BLOCK)/$$d"; \
		if [ -d "$$t" ]; then du -sh "$$t" 2>/dev/null | sed 's/^/  /'; any=1; \
		else echo "  (absent)  $$t"; fi; \
	done; \
	if [ "$$any" -eq 0 ]; then echo "Nothing to clean."; exit 0; fi; \
	printf 'Confirm removal of ALL of the above? [y/N] '; \
	read -r response; \
	case "$$response" in \
		y|Y|yes|YES) \
			for d in stratus genus xcelium innovus; do \
				rm -rf "$(LAMBDA_WORK)/$(BLOCK)/$$d"; \
			done; \
			echo "Removed.";; \
		*) echo "Aborted."; exit 1;; \
	esac

# ============================================================================
# FLOW DAG (intent; activate once real RTL + a readable PDK land)
# ----------------------------------------------------------------------------
# The back-end is a file pipeline routed through the release/ contract so that
# a messy run never poisons the next stage's input. Source = src/, run = run/,
# handoff = release/:
#
#   src/blocks/<b>/<b>.cpp ──(Stratus)──▶ $(LAMBDA_WORK)/<b>/stratus/<CFG>/<b>.v
#                          ──(Genus)────▶ $(LAMBDA_WORK)/<b>/release/<b>.mapped.v
#                          ──(Innovus)──▶ $(LAMBDA_WORK)/<b>/release/<b>.routed.{def,v,gds}
#                          ──(Pegasus)──▶ $(LAMBDA_WORK)/<b>/pegasus/<b>.drc.rpt
#                          ──(Xcelium)──▶ $(LAMBDA_WORK)/<b>/xcelium/<run-id>/waves.shm
#                          ──(Verisium)─▶ (GUI; no file output, attaches to waves)
#
# When real inputs exist, replace the phony targets above with file targets so
# `make innovus` rebuilds only the stale stages, e.g.:
#
#   $(LAMBDA_WORK)/$(BLOCK)/stratus/$(CFG)/$(BLOCK).v: src/blocks/$(BLOCK)/$(BLOCK).cpp
#       $(LAMBDA_STRAT) $(BLOCK) batch $(CFG)
#   $(LAMBDA_WORK)/$(BLOCK)/release/$(BLOCK).mapped.v: \
#       $(LAMBDA_WORK)/$(BLOCK)/stratus/$(CFG)/$(BLOCK).v
#       $(LAMBDA_GENUS) $(BLOCK) batch synth
#   $(LAMBDA_WORK)/$(BLOCK)/release/$(BLOCK).routed.def: \
#       $(LAMBDA_WORK)/$(BLOCK)/release/$(BLOCK).mapped.v
#       $(LAMBDA_INNO) $(BLOCK) batch route
#
# Not activated yet because (a) no HLS C++ source exists, and (b) no TSMC
# N16FFC PDK is on the chamber (only gpdk + skywater), so init_design/route
# have no real tech to target. Keeping these as comments instead of fake file
# targets is deliberate: a file target whose recipe can't run is worse than an
# honest phony alias. See docs/tools-overview.md "Filesystem & run-area".
# ============================================================================
