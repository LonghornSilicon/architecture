#!/usr/bin/env bash
# ============================================================================
# lambda-env.sh
# ----------------------------------------------------------------------------
# Committed defaults for Lambda chamber tooling. Sourced by every lambda-*
# launcher AND by every generic helper in tools/bin/ (stratus-gui etc).
#
# Per-user / per-machine overrides go in ~/.longhorn/lambda.env (gitignored,
# parallel to ~/.longhorn/chamber.env used by sync-chamber.sh).
#
# Variables defined here use the ${VAR:=default} form so anything already in
# the environment wins. Sourcing this file is idempotent.
# ============================================================================

# ---- Project paths ---------------------------------------------------------
: "${LAMBDA_ROOT:=$HOME/architecture}"
: "${LAMBDA_SCRATCH:=/rscratch/$USER/lambda}"
: "${LAMBDA_LOGS:=$LAMBDA_SCRATCH/logs}"
: "${LAMBDA_BUILD:=$LAMBDA_ROOT/build}"

# ---- Chamber SGE queue -----------------------------------------------------
: "${LAMBDA_QUEUE:=normal.q}"

# ---- Cadence tool module pins ---------------------------------------------
# These pin to the versions documented in docs/chamber-sync-setup.md /
# the chamber command reference. Override per-user in ~/.longhorn/lambda.env
# if you need a different one. lambda-diagnose verifies availability.
: "${STRATUS_VERSION:=22.01.009}"
: "${STRATUS_MODULE:=stratus/2201/${STRATUS_VERSION}}"
: "${XCELIUM_VERSION:=21.09.009}"
: "${XCELIUM_MODULE:=xcelium/2109/${XCELIUM_VERSION}}"
# Module roots below are the NEWEST observed on the chamber modulefiles tree
# (/home/cm_admin/modules/Linux/modulefiles/, enumerated over SFTP 2026-06-06).
# They pin the TOOL versions and are independent of PDK availability: the tools
# load fine, but no TSMC N16FFC PDK is on the chamber yet (only gpdk + skywater
# under /process/hosted), so real signoff against the real process is still
# gated by LAMBDA_PDK_MODULE.
: "${GENUS_MODULE:=genus/211}"     # observed: genus/{172,181,191,201,211}
: "${INNOVUS_MODULE:=innovus/251}" # observed: innovus/{171,181,191,201,211,251} (25.1)
: "${PEGASUS_MODULE:=pegasus/251}" # observed: pegasus/{204..251} — DRC/LVS signoff
: "${SSV_MODULE:=ssv/251}"         # observed: ssv/{172..251} — Tempus/Voltus/Quantus
: "${VIRTUOSO_MODULE:=}"           # ic/icadv/icadvm present; pin when needed
: "${LAMBDA_PDK_MODULE:=}"         # no TSMC N16FFC on chamber — pending PDK delivery

# ---- Lambda block list (canonical) ----------------------------------------
# Source of truth for which block names lambda-* launchers accept.
# Order matches src/README.md HLS build order (long poles first).
LAMBDA_BLOCKS=(mate kce vecu tiu msc lsu hif)

# ---- Per-user overrides ----------------------------------------------------
# Loaded last so user values win for everything except LAMBDA_BLOCKS (which
# is a project invariant and should not be overridden per-user).
if [[ -f "$HOME/.longhorn/lambda.env" ]]; then
    # shellcheck disable=SC1091
    source "$HOME/.longhorn/lambda.env"
fi

# ---- Bootstrap module() in non-interactive bash ----------------------------
# Chamber compute nodes run csh interactively; the Modules system is set up
# at login via shell rc. When we invoke a launcher from a script (or via
# `qsub`), bashrc is not sourced and `module` is not in scope. Try common
# init paths; ignore failure (lambda-diagnose / chamber-diagnose report it).
#
# Per-chamber path varies. If none of the fallbacks match this chamber,
# discover the correct path and set LAMBDA_MODULE_INIT in
# ~/.longhorn/lambda.env:
#
#   bash $ find / -name 'modulecmd' -type f 2>/dev/null | head -3
#   bash $ find / -name '*.sh' -path '*module*init*' 2>/dev/null | head -3
#   csh  $ which modulecmd; echo $MODULEPATH
#
# Then in ~/.longhorn/lambda.env:
#   export LAMBDA_MODULE_INIT=/the/path/to/init/bash
if ! type module >/dev/null 2>&1; then
    if [[ -n "${LAMBDA_MODULE_INIT:-}" ]] && [[ -f "$LAMBDA_MODULE_INIT" ]]; then
        # Per-user override always wins
        # shellcheck disable=SC1090
        source "$LAMBDA_MODULE_INIT"
    elif [[ -n "${MODULESHOME:-}" ]] && [[ -f "${MODULESHOME}/init/bash" ]]; then
        # Standard Environment Modules layout: $MODULESHOME/init/<shell>.
        # MODULESHOME is usually inherited from the parent csh shell (set by
        # /etc/csh.cshrc or equivalent). This auto-detects any chamber that
        # exports it. Verified on ae03ut01 (UT/Cadence): MODULESHOME =
        # /apps/modules-v3.2.6a-64bit/Modules; init/bash works.
        # shellcheck disable=SC1090
        source "${MODULESHOME}/init/bash"
    else
        # Last-resort static fallback list (covers chambers that don't export
        # MODULESHOME). If none match, set LAMBDA_MODULE_INIT in
        # ~/.longhorn/lambda.env per the discovery commands in chamber-diagnose.
        for _init in \
            /etc/profile.d/modules.sh \
            /etc/profile.d/lmod.sh \
            /etc/profile.d/cadence.sh \
            /etc/profile.d/cad.sh \
            /usr/share/Modules/init/bash \
            /usr/share/lmod/lmod/init/bash \
            /usr/share/modules/init/bash \
            /apps/modules-v3.2.6a-64bit/Modules/init/bash \
            /apps/hosted/Modules/init/bash \
            /apps/hosted/modules/init/bash \
            /apps/Modules/default/init/bash \
            /apps/Modules/init/bash \
            /apps/modules/init/bash \
            /grid/common/pkgs/Modules/init/bash \
            /grid/common/pkgs/Modules/default/init/bash \
            /grid/common/pkgs/lmod/lmod/init/bash \
            /grid/common/pkgs/modules/init/bash \
            /opt/modules/init/bash \
            /opt/Modules/init/bash \
            /cad/scripts/modules.sh \
            /cad/Modules/init/bash; do
            if [[ -f "$_init" ]]; then
                # shellcheck disable=SC1090
                source "$_init"
                break
            fi
        done
        unset _init
    fi
fi

# ---- Ensure scratch + logs exist; fall back to /tmp if not writable -------
# /rscratch is node-local on some chambers and /rscratch/<user>/ is sometimes
# only provisioned on the utility node (not on compute nodes). If we can't
# write to LAMBDA_SCRATCH, fall back to /tmp/<user>-lambda so logs and
# transient artifacts still land somewhere. Per-user override is still
# possible via ~/.longhorn/lambda.env.
mkdir -p "$LAMBDA_SCRATCH" "$LAMBDA_LOGS" 2>/dev/null || true
if [[ ! -w "$LAMBDA_SCRATCH" ]] || [[ ! -d "$LAMBDA_SCRATCH" ]]; then
    LAMBDA_SCRATCH="/tmp/${USER}-lambda"
    LAMBDA_LOGS="$LAMBDA_SCRATCH/logs"
    mkdir -p "$LAMBDA_SCRATCH" "$LAMBDA_LOGS" 2>/dev/null
    export LAMBDA_SCRATCH LAMBDA_LOGS
fi
