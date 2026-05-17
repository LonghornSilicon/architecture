# ============================================================================
# Stratus HLS project: MatE — 8x8 INT8xINT4 systolic
# ----------------------------------------------------------------------------
# Spec source:    ../../../../arch.yml   block id `matrix_engine`
# Block README:   ../README.md
# Build commands: lambda-stratus mate gui
#                 lambda-stratus mate batch BASIC
#
# STATUS: STUB
# ----
# This is a placeholder project file committed alongside the v0.1 launcher
# infrastructure (tools/bin/lambda-stratus). It exists so the launcher has
# something to open and exercise end-to-end. It will NOT produce real RTL
# until the SystemC HLS source (pe.h/.cpp, mate.h/.cpp, tb/) lands in this
# block per the build order in src/README.md (MatE PE first).
#
# Canonical syntax for when HLS source lands (pattern source: ESP Columbia
# accelerators/stratus_hls/spmv/stratus/project.tcl):
#
#   define_hls_module MatE [list ../pe.cpp ../mate.cpp]
#
#   define_hls_config MatE BASIC \
#       --clock_period=1.0           ;# 1 GHz, arch.yml target_clock_mhz
#
#   define_hls_config MatE FALLBACK \
#       --clock_period=1.25          ;# 800 MHz fallback
#
#   define_sim_config BASIC_sim "MatE BEH" \
#       -argv "[list ../tb/data/in.txt]"
#
# Notes:
#   - define_hls_config signature: <module> <config_name> [flags]
#   - Clock-period flag is --clock_period= (double-dash, equals, no space)
#   - Preprocessor defines: -DMACRO=val go after the config name
#   - lib_map_file (technology mapping) gets set once TSMC N16FFC PDK module
#     is available on the chamber.
# ============================================================================

# ---- Project identity ------------------------------------------------------
set BLOCK     mate
set TOP       MatE

# Output dir: tools/lib/lambda-env.sh sets LAMBDA_BUILD=<repo>/build, but
# Stratus runs from src/blocks/mate/stratus/, so this is relative.
# Equivalent absolute path: $LAMBDA_BUILD/$BLOCK/stratus/
set BUILD_DIR ../../../../build/$BLOCK/stratus

# ---- Stub: no Stratus commands until HLS source lands ----------------------
# When pe.cpp / mate.cpp / tb/ are written, uncomment the define_hls_module +
# define_hls_config + define_sim_config block in the comments above. Until
# then, this file just provides a parseable Tcl project so the IDE opens
# cleanly with an empty source tree (no error dialog).

# Project attributes that don't require a module
# (set_attr can be applied globally; per-module attributes attach later)
# set_attr message_detail 2

# (intentionally empty below)
