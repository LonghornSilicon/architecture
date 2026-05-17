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
# When the HLS source lands, uncomment the HLS_SOURCES / TB_SOURCES lists
# below and remove this STATUS block.
# ============================================================================

# ---- Project identity ------------------------------------------------------
set BLOCK     mate
set TOP       MatE

# Output dir: tools/lib/lambda-env.sh sets LAMBDA_BUILD=<repo>/build,
# but Stratus runs from src/blocks/mate/stratus/, so this is relative.
# Equivalent absolute path: $LAMBDA_BUILD/$BLOCK/stratus/
set BUILD_DIR ../../../../build/$BLOCK/stratus

# ---- Source files (stub — uncomment when HLS source lands) -----------------
# set HLS_SOURCES [list \
#     ../pe.cpp   \
#     ../mate.cpp \
# ]
# set TB_SOURCES [list \
#     ../tb/main.cpp   \
#     ../tb/system.cpp \
# ]
set HLS_SOURCES [list]
set TB_SOURCES  [list]

# ---- HLS module ------------------------------------------------------------
# Defines the synthesizable top. INT8 (Q) x INT4 (W) per arch.yml MatE block.
# Clock pinned to 1.0 ns target (1 GHz, matching arch.yml process.target_clock_mhz).
if {[llength $HLS_SOURCES] > 0} {
    define_hls_module $TOP $HLS_SOURCES -clock_period 1.0
}

# ---- HLS configurations ----------------------------------------------------
# BASIC:    1 GHz target (arch.yml baseline)
# FALLBACK: 800 MHz target (arch.yml process.target_clock_mhz fallback)
#
# Note: macro-define flag syntax (e.g. -DCLOCK_PERIOD=1.0) is version-specific
# in Stratus and requires the actual flag name from the 22.01.009 reference
# manual. For the stub project, we define configs without macros so the IDE
# parses cleanly; the macros + per-config flags get added alongside the real
# HLS source when MatE PE work begins. See arch.yml block matrix_engine.
define_hls_config BASIC
define_hls_config FALLBACK

# ---- Simulation configurations ---------------------------------------------
if {[llength $TB_SOURCES] > 0} {
    define_sim_config BASIC    $TB_SOURCES
    define_sim_config FALLBACK $TB_SOURCES
}

# ---- Project attributes ----------------------------------------------------
set_attr message_detail       2
set_attr default_input_delay  0.1
set_attr default_output_delay 0.1

# ---- Technology mapping ----------------------------------------------------
# Set once the TSMC N16FFC project module is available on the chamber
# (currently gated on the support case in docs/chamber-sync-setup.md).
# Example: set_attr lib_map_file "/process/hosted/tsmc/n16ffc/.../stdcell.lib"
# set_attr lib_map_file ""
