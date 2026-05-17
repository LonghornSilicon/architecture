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
: "${GENUS_MODULE:=}"        # set when known + PDK case clears
: "${INNOVUS_MODULE:=}"      # set when known + PDK case clears
: "${VIRTUOSO_MODULE:=}"     # set when known
: "${LAMBDA_PDK_MODULE:=}"   # e.g., projects/<pdk>/<sub> — pending support case

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
# `qsub`), bashrc is not sourced and `module` is not in scope. Try the
# standard init paths; ignore failure (lambda-diagnose reports it).
if ! type module >/dev/null 2>&1; then
    for _init in /etc/profile.d/modules.sh \
                 /usr/share/Modules/init/bash \
                 /apps/hosted/Modules/init/bash \
                 /opt/modules/init/bash; do
        if [[ -f "$_init" ]]; then
            # shellcheck disable=SC1090
            source "$_init"
            break
        fi
    done
    unset _init
fi

# ---- Ensure scratch + logs exist ------------------------------------------
mkdir -p "$LAMBDA_SCRATCH" "$LAMBDA_LOGS" 2>/dev/null || true
