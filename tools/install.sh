#!/usr/bin/env bash
# ============================================================================
# tools/install.sh
# ----------------------------------------------------------------------------
# Idempotent installer for the Lambda chamber tooling. Run once per chamber
# account after the repo is synced via sync-promote. Re-runs are safe: it
# only symlinks files that aren't already correctly symlinked and never
# mutates the user's dotfiles.
#
# What it does:
#   1. Ensures ~/bin/ exists.
#   2. Symlinks every file in tools/bin/ into ~/bin/.
#   3. Marks all tools/bin/* and tools/install.sh executable.
#   4. Ensures $LAMBDA_SCRATCH and $LAMBDA_LOGS exist.
#   5. Prints PATH advice if ~/bin/ is not on $PATH (never auto-edits rc files).
#   6. Runs lambda-diagnose as the final step so any issues surface immediately.
#
# Usage: bash ~/architecture/tools/install.sh
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_SRC="$SCRIPT_DIR/bin"
BIN_DST="$HOME/bin"

# ---- Cosmetic helpers ------------------------------------------------------
if [[ -t 1 ]]; then
    GREEN=$'\e[32m'; YELLOW=$'\e[33m'; BOLD=$'\e[1m'; RESET=$'\e[0m'
else
    GREEN=""; YELLOW=""; BOLD=""; RESET=""
fi

# ---- 0. Sanity ------------------------------------------------------------
if [[ ! -d "$BIN_SRC" ]]; then
    echo "ERROR: source dir not found: $BIN_SRC" >&2
    echo "Expected layout: <repo>/tools/{bin,lib,install.sh}" >&2
    exit 1
fi

echo "${BOLD}Lambda chamber tools installer${RESET}"
echo "  source: $BIN_SRC"
echo "  dest:   $BIN_DST"
echo ""

# ---- 1. Make ~/bin/ -------------------------------------------------------
mkdir -p "$BIN_DST"

# ---- 2. chmod the source side first ---------------------------------------
chmod +x "$BIN_SRC"/* "$SCRIPT_DIR/install.sh" 2>/dev/null || true

# ---- 3. Symlink each launcher into ~/bin/ ---------------------------------
linked=0
skipped=0
for src in "$BIN_SRC"/*; do
    [[ -f "$src" ]] || continue
    name=$(basename "$src")
    dst="$BIN_DST/$name"
    # If symlink already points to correct source, skip
    if [[ -L "$dst" ]] && [[ "$(readlink "$dst")" == "$src" ]]; then
        skipped=$((skipped + 1))
        continue
    fi
    # If something else exists at dst, back it up rather than overwriting
    if [[ -e "$dst" ]] && [[ ! -L "$dst" ]]; then
        bk="$dst.bak.$(date +%s)"
        mv "$dst" "$bk"
        echo "  ${YELLOW}backed up${RESET} existing $dst -> $bk"
    fi
    ln -sf "$src" "$dst"
    echo "  ${GREEN}linked${RESET}    $name"
    linked=$((linked + 1))
done

echo ""
echo "Installed: $linked new, $skipped already up-to-date."

# ---- 4. Source env to set LAMBDA_SCRATCH etc., then mkdir if needed -------
# shellcheck source=lib/lambda-env.sh
source "$SCRIPT_DIR/lib/lambda-env.sh"
echo "  scratch:  $LAMBDA_SCRATCH"
echo "  logs:     $LAMBDA_LOGS"

# ---- 5. PATH check (never auto-edit dotfiles) -----------------------------
if ! echo "$PATH" | tr ':' '\n' | grep -qx "$BIN_DST"; then
    echo ""
    echo "${YELLOW}NOTE:${RESET} $BIN_DST is not on \$PATH. Add this line to your shell rc:"
    case "${SHELL:-}" in
        */csh|*/tcsh)
            echo "    set path = ( $BIN_DST \$path )         # add to ~/.cshrc or ~/.tcshrc"
            ;;
        *)
            echo "    export PATH=\"$BIN_DST:\$PATH\"        # add to ~/.bashrc or ~/.profile"
            ;;
    esac
    echo "Then: source the rc file, or open a new shell."
fi

# ---- 6. Run lambda-diagnose so any issues surface immediately --------------
echo ""
echo "${BOLD}--- lambda-diagnose ---${RESET}"
# May fail if LAMBDA_ROOT missing; non-fatal here so installer can still exit 0
# (informational output only)
"$BIN_DST/lambda-diagnose" || true

echo ""
echo "${BOLD}Install complete.${RESET} Try:"
echo "    lambda-stratus mate diagnose"
echo "    lambda-stratus mate gui          # opens IDE on stub project"
