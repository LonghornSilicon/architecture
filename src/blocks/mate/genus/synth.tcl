# ============================================================================
# Genus (Common UI) synthesis flow stub: MatE — 8x8 INT8xINT4 systolic
# ----------------------------------------------------------------------------
# Spec source:  ../../../../arch.yml   block id `matrix_engine`
# Block README: ../README.md
# Run with:     lambda-genus mate batch synth     (headless)
#               lambda-genus mate gui              (interactive + GUI)
#               lambda-genus mate shell            (text REPL; then `source synth.tcl`)
#
# STATUS: STUB
# ----
# This is a placeholder Common-UI synth flow committed alongside the v0.4
# Genus launcher (tools/bin/lambda-genus). It exists so the launcher has a
# flow to source end-to-end, and to document canonical Genus Common UI syntax.
# It does NOT run real synthesis yet, for two concrete reasons:
#
#   1. No RTL.  HLS source for MatE (pe.cpp/mate.cpp) is not written yet, so
#      Stratus has not emitted a netlist (read_hdl needs Verilog input).
#   2. No PDK.  The chamber has no TSMC N16FFC PDK (only gpdk + skywater under
#      /process/hosted). advgpdk (= cds_ff_mpt) is the only FinFET-class
#      vehicle; its .lib/.lef paths must be wired from an ETX session before
#      they can land here (the repo-sync SFTP channel cannot read PDK files).
#
# Until then this stub just confirms the launcher reaches Genus, loads cleanly,
# and can source a Tcl file. It prints a banner and (in batch) exits.
#
# ----------------------------------------------------------------------------
# Canonical Common-UI synth skeleton for when RTL + PDK land
# (Cadence Genus 21.1 Common UI; matches innovus/211/21.18.000 for clean DB):
#
#   set_db init_lib_search_path { <pdk-lib-dir> }
#   set_db library [list <stdcells>.lib]
#   # Genus runs from $LAMBDA_WORK/mate/genus/<run-id>/; Stratus output lives
#   # at $LAMBDA_WORK/mate/stratus/BASIC/mate.v (one level up, sibling stage).
#   # Read via env so paths are reproducible regardless of CWD.
#   read_hdl $::env(LAMBDA_WORK)/mate/stratus/BASIC/mate.v
#   elaborate MatE
#   read_sdc $::env(LAMBDA_ROOT)/src/blocks/mate/genus/mate.sdc   ;# constraints (in git)
#   syn_generic
#   syn_map
#   syn_opt
#   write_hdl > outputs/mate.mapped.v                              ;# launcher publishes to release/
#   write_sdc > outputs/mate.mapped.sdc
#   report_timing       > reports/timing.rpt
#   report_area         > reports/area.rpt
#   report_power        > reports/power.rpt
#   # quit handled by GENUS_BATCH guard below; launcher's lambda_publish_release
#   # copies outputs/mate.mapped.v → $LAMBDA_WORK/mate/release/mate.mapped.v
#   # so Innovus reads from release/ via the cross-stage handoff contract.
#
# Notes (verified against the Genus Common UI guide, 2026-06-06):
#   - Common UI is Genus's DEFAULT — no -stylus needed (asymmetric with Innovus).
#   - `-legacy_ui` opts out, do not pass it.
#   - All artifacts land in this run dir (build via lambda_rundir under
#     $LAMBDA_WORK/mate/genus/<run-id>/, gitignored).
# ============================================================================

puts ""
puts "============================================================"
puts " MatE Genus synth flow STUB — launcher reached Genus OK."
puts " Common UI active (default). No RTL loaded; no PDK targeted."
puts " GUI: type 'gui_show'  |  Common-UI synth skeleton above."
puts "============================================================"
puts ""

# Create the outputs/ and reports/ subdirs the real flow will populate, so
# downstream lambda_publish_release sees a stable layout once HLS lands.
file mkdir outputs reports

# In batch mode the wrapper expects the flow to terminate (a headless
# `genus -files ...` would hang at the prompt otherwise). The wrapper
# `genus-here` exports GENUS_BATCH=1; we key off that — pure Tcl
# (`info exists`), no reliance on Cadence command names.
if {[info exists ::env(GENUS_BATCH)]} {
    puts "stub: batch mode, exiting."
    exit 0
}
