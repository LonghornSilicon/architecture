# ============================================================================
# Lambda — chamber flow Makefile
# ----------------------------------------------------------------------------
# Ergonomic top layer over the tools/bin/ launchers. RUN THIS ON THE CHAMBER,
# from an interactive ETX/X11 session, after `sync-promote` + tools/install.sh.
# It is NOT runnable on the Mac (no Cadence tools / no chamber there).
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
#   make diag                              # full chamber + Lambda probe
# ============================================================================

# ---- Knobs (override on the command line: `make hls BLOCK=kce CFG=FALLBACK`) -
BLOCK ?= mate
CFG   ?= BASIC

# Launchers are on $PATH via tools/install.sh (~/bin symlinks). Fall back to the
# in-repo path so `make` works even before install.sh has run.
BIN          := $(HOME)/architecture/tools/bin
LAMBDA_STRAT := $(shell command -v lambda-stratus 2>/dev/null || echo $(BIN)/lambda-stratus)
LAMBDA_INNO  := $(shell command -v lambda-innovus 2>/dev/null || echo $(BIN)/lambda-innovus)
LAMBDA_DIAG  := $(shell command -v lambda-diagnose 2>/dev/null || echo $(BIN)/lambda-diagnose)

.DEFAULT_GOAL := help

# ---- Phony ergonomic targets (work today) ----------------------------------
.PHONY: help diag gui hls hls-report hls-clean innovus innovus-shell \
        innovus-batch innovus-diag innovus-clean clean

help:
	@echo "Lambda chamber flow — run from an ETX session on the chamber."
	@echo ""
	@echo "Variables:  BLOCK=$(BLOCK)   CFG=$(CFG)   (override on the CLI)"
	@echo "Blocks:     mate kce vecu tiu msc lsu hif"
	@echo ""
	@echo "Diagnostics:"
	@echo "  make diag                     full chamber + Lambda probe"
	@echo ""
	@echo "HLS (Stratus):"
	@echo "  make gui          BLOCK=$(BLOCK)            open Stratus IDE"
	@echo "  make hls          BLOCK=$(BLOCK) CFG=$(CFG)   headless cynth"
	@echo "  make hls-report   BLOCK=$(BLOCK) CFG=$(CFG)   tail latest HLS log"
	@echo "  make hls-clean    BLOCK=$(BLOCK)            rm build/<block>/stratus"
	@echo ""
	@echo "Place & route (Innovus, Stylus Common UI):"
	@echo "  make innovus        BLOCK=$(BLOCK)          Innovus + GUI"
	@echo "  make innovus-shell  BLOCK=$(BLOCK)          Innovus text REPL"
	@echo "  make innovus-batch  BLOCK=$(BLOCK) FLOW=setup  headless flow"
	@echo "  make innovus-diag   BLOCK=$(BLOCK)          paths + module check"
	@echo "  make innovus-clean  BLOCK=$(BLOCK)          rm build/<block>/innovus"

diag:
	@$(LAMBDA_DIAG)

# --- HLS ---
gui:
	@$(LAMBDA_STRAT) $(BLOCK) gui
hls:
	@$(LAMBDA_STRAT) $(BLOCK) batch $(CFG)
hls-report:
	@$(LAMBDA_STRAT) $(BLOCK) report $(CFG)
hls-clean:
	@$(LAMBDA_STRAT) $(BLOCK) clean

# --- Innovus ---
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

clean: hls-clean innovus-clean

# ============================================================================
# FLOW DAG (intent; activate once real RTL + a readable PDK land)
# ----------------------------------------------------------------------------
# The back-end is a file pipeline:
#
#   src/blocks/<b>/<b>.cpp ──(Stratus)──▶ build/<b>/stratus/<CFG>/<b>.v
#                          ──(Genus)────▶ build/<b>/genus/<b>.mapped.v
#                          ──(Innovus)──▶ build/<b>/innovus/<b>.routed.{def,v,gds}
#                          ──(Pegasus)──▶ build/<b>/pegasus/<b>.drc.rpt
#
# Make models this natively. When the inputs exist, replace the phony targets
# above with file targets so `make drc` rebuilds only the stale stages, e.g.:
#
#   build/$(BLOCK)/stratus/$(CFG)/$(BLOCK).v: src/blocks/$(BLOCK)/$(BLOCK).cpp
#       $(LAMBDA_STRAT) $(BLOCK) batch $(CFG)
#   build/$(BLOCK)/innovus/$(BLOCK).routed.def: build/$(BLOCK)/genus/$(BLOCK).mapped.v
#       $(LAMBDA_INNO) $(BLOCK) batch route
#
# Not activated yet because (a) no HLS C++ source exists, and (b) no TSMC
# N16FFC PDK is on the chamber (only gpdk + skywater), so init_design/route
# have no real tech to target. Keeping these as comments instead of fake file
# targets is deliberate: a file target whose recipe can't run is worse than an
# honest phony alias. See docs/tools-overview.md.
# ============================================================================
