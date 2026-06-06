# ============================================================================
# Innovus (Stylus Common UI) flow stub: MatE — 8x8 INT8xINT4 systolic
# ----------------------------------------------------------------------------
# Spec source:  ../../../../arch.yml   block id `matrix_engine`
# Block README: ../README.md
# Run with:     lambda-innovus mate batch setup     (headless)
#               lambda-innovus mate gui              (interactive + GUI)
#               lambda-innovus mate shell            (text REPL; then `source setup.tcl`)
#
# STATUS: STUB
# ----
# This is a placeholder Stylus flow committed alongside the v0.2 Innovus
# launcher (tools/bin/lambda-innovus). It exists so the launcher has a flow to
# source end-to-end, and to document canonical Stylus Common UI syntax. It does
# NOT run a real implementation flow yet, for two concrete reasons:
#
#   1. No RTL.  Genus has not emitted a MatE netlist (HLS source pe.cpp/mate.cpp
#      is not written; see src/README.md build order). init_design needs a
#      netlist + constraints.
#   2. No PDK.  There is no TSMC N16FFC PDK on the chamber (only gpdk + skywater
#      under /process/hosted). advgpdk is the only FinFET-class vehicle, and its
#      LEF/LIB/QRC tech-file paths must be read from an ETX session before they
#      can be wired here (the repo-sync SFTP channel cannot read PDK files).
#
# Until then this stub just confirms the launcher reaches Innovus, opens the
# GUI, and can source a Tcl file. It prints a banner and (in batch) exits.
#
# ----------------------------------------------------------------------------
# Canonical Stylus Common UI flow skeleton for when RTL + PDK land
# (Innovus Foundation Flow ordering; fill MMMC + paths from the PDK):
#
#   read_mmmc   mmmc.tcl                ;# corners, libs, constraints
#   read_physical -lef [list <tech.lef> <std.lef> <macro.lef>]
#   read_netlist  ../../genus/mate.v    ;# from lambda-genus mate (v0.5)
#   init_design
#   # floorplan
#   create_floorplan -core_density_size 0.70 -core_to_*_dist 5.0
#   # power
#   read_power_intent / connect_global_net ...
#   # place
#   place_opt_design
#   # clock
#   create_clock_tree_spec ; clock_opt_design
#   # route
#   route_design
#   # signoff handoff
#   write_db        mate.routed
#   write_netlist   mate.routed.v
#   write_def       mate.routed.def
#   # -> Pegasus DRC/LVS (lambda-pegasus, v0.5), Tempus/SSV STA, Quantus RC
#
# Notes (verified against Innovus Stylus Common UI User Guide + Stylus Text
# Command Reference; chamber pins innovus/211/21.18.000 for matched DB family
# with genus/211/21.18.000 — see docs/tools-overview.md "Chamber execution model"):
#   - GUI control is `gui_show` / `gui_hide` (legacy UI used `win`).
#   - All artifacts land in this run dir under $LAMBDA_WORK/mate/innovus/<run-id>,
#     gitignored (lives in ~/work/lambda, NOT in the repo mirror).
# ============================================================================

puts ""
puts "============================================================"
puts " MatE Innovus flow STUB — launcher reached Innovus OK."
puts " Stylus Common UI active. No design loaded (no RTL, no PDK)."
puts " GUI: type 'gui_show'  |  Foundation-flow skeleton above."
puts "============================================================"
puts ""

# In batch mode the wrapper expects the flow to terminate (otherwise a headless
# `innovus -files ...` would hang at the prompt waiting for input). The wrapper
# `innovus-here` sets INNOVUS_BATCH=1 only for batch mode, so we key off that —
# pure Tcl (`info exists`), no reliance on any Cadence command name. When the
# stub is sourced interactively (gui/shell), INNOVUS_BATCH is unset and the
# session stays alive.
if {[info exists ::env(INNOVUS_BATCH)]} {
    puts "stub: batch mode, exiting."
    exit 0
}
