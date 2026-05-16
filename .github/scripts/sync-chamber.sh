#!/usr/bin/env bash
#
# Sync the architecture repo to a Longhorn Silicon teammate's Cadence chamber.
# Invoked by .github/workflows/sync-chamber.yml on push to main.
# Also runnable standalone for smoke-testing:
#     cd <repo-root> && bash .github/scripts/sync-chamber.sh
#
# How it works (V2 — git bundles):
#
# Chamber constraints: SFTP allows CREATE but blocks OVERWRITE and DELETE,
# and SSH exec is blocked. So we cannot mirror file trees in place.
#
# Instead, each push generates a single git bundle of `main` and uploads it
# to ~/inbox/architecture-<timestamp>-<sha>.bundle on the chamber. The bundle
# filename is unique per push so no overwrite is needed.
#
# On the chamber side, in an ETX shell (where real `git` and `mv` work
# normally), the user runs `sync-promote` which:
#     cd ~/architecture
#     git fetch <newest bundle> main:refs/heads/main
#     git reset --hard main
#
# This gives the chamber a real git repo with full history and incremental
# updates that only add new objects, regardless of how many bundles have been
# uploaded.
#
# Per-runner config: ~/.longhorn/chamber.env (NOT committed).
# Chamber password: macOS Keychain (service 'longhorn-chamber' by default).

set -euo pipefail

# Ensure brew-installed binaries are found, both interactively and in the
# GH Actions runner service (which has a minimal PATH).
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

CONFIG="$HOME/.longhorn/chamber.env"
if [[ ! -f "$CONFIG" ]]; then
  echo "::error::$CONFIG missing. See docs/chamber-sync-setup.md for setup."
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$CONFIG"
set +a

: "${CHAMBER_HOST:?CHAMBER_HOST not set in $CONFIG}"
: "${CHAMBER_PORT:?CHAMBER_PORT not set in $CONFIG}"
: "${CHAMBER_USER:?CHAMBER_USER not set in $CONFIG}"
: "${CHAMBER_PATH:?CHAMBER_PATH not set in $CONFIG}"

# Default inbox path if not overridden in chamber.env
CHAMBER_INBOX="${CHAMBER_INBOX:-/home/${CHAMBER_USER}/inbox/}"

for bin in lftp sshpass git; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "::error::$bin not installed. See docs/chamber-sync-setup.md."
    exit 1
  fi
done

# Resolve password. Two supported sources:
#   1. CHAMBER_PASSWORD set in chamber.env (preferred for LaunchAgent contexts
#      where macOS Keychain access is unreliable). File mode 0600 + gitignore
#      provides equivalent practical security to Keychain -A.
#   2. macOS Keychain (preferred for interactive / one-off runs).
if [[ -n "${CHAMBER_PASSWORD:-}" ]]; then
  PW="$CHAMBER_PASSWORD"
else
  KEYCHAIN_SERVICE="${CHAMBER_KEYCHAIN_SERVICE:-longhorn-chamber}"
  if ! PW=$(security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$USER" -w 2>/dev/null); then
    echo "::error::No password source. Set CHAMBER_PASSWORD in ~/.longhorn/chamber.env"
    echo "::error::OR add Keychain entry: security add-generic-password -s $KEYCHAIN_SERVICE -a \$USER -w"
    exit 1
  fi
fi
export SSHPASS="$PW"

SOURCE_DIR="${GITHUB_WORKSPACE:-$(pwd)}"
cd "$SOURCE_DIR"

# Sanity check: we are in a git repo with a main branch and full history.
if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "::error::$SOURCE_DIR is not a git repo."
  exit 1
fi
if ! git rev-parse --verify main >/dev/null 2>&1; then
  echo "::error::no 'main' branch in $SOURCE_DIR. Bundle requires main."
  exit 1
fi
if [[ "$(git rev-list --count --all)" -eq 1 ]] && [[ -n "${GITHUB_ACTIONS:-}" ]]; then
  echo "::warning::Shallow checkout detected in CI. Bundle will have only one commit."
  echo "::warning::Set 'fetch-depth: 0' on actions/checkout step."
fi

# Build a unique bundle name: timestamp ensures uniqueness, SHA identifies content.
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
if [[ -n "${GITHUB_SHA:-}" ]]; then
  SHA_SHORT="${GITHUB_SHA:0:7}"
else
  SHA_SHORT="$(git rev-parse --short=7 main 2>/dev/null || echo manual)"
fi

BUNDLE_NAME="architecture-${TIMESTAMP}-${SHA_SHORT}.bundle"
BUNDLE_LOCAL="${TMPDIR:-/tmp}/${BUNDLE_NAME}"
BUNDLE_REMOTE="${CHAMBER_INBOX%/}/${BUNDLE_NAME}"

# Always bundle main + HEAD. Including HEAD makes `git clone <bundle>` work
# without manual ref-setting (bundle with main only fails with "remote HEAD
# refers to nonexistent ref"). Chamber-side git fetch deduplicates objects,
# so resending full history every time only writes new objects to
# ~/architecture/.git/.
echo "Bundling main (HEAD=$(git rev-parse --short=7 main))..."
git bundle create "$BUNDLE_LOCAL" main HEAD

# Sanity: lint the bundle so we don't ship a corrupt one.
if ! git bundle verify "$BUNDLE_LOCAL" >/dev/null 2>&1; then
  echo "::error::Bundle verification failed: $BUNDLE_LOCAL"
  rm -f "$BUNDLE_LOCAL"
  exit 1
fi

SIZE=$(du -h "$BUNDLE_LOCAL" | cut -f1)
echo "Bundle: $BUNDLE_LOCAL ($SIZE)"
echo "Target: ${CHAMBER_USER}@${CHAMBER_HOST}:${BUNDLE_REMOTE}"

lftp -p "$CHAMBER_PORT" "sftp://${CHAMBER_HOST}" <<EOF
set sftp:auto-confirm yes
set sftp:connect-program "sshpass -e ssh -a -x -o ConnectTimeout=10 -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa -o StrictHostKeyChecking=accept-new"
user ${CHAMBER_USER} dummy
mkdir -fp "${CHAMBER_INBOX%/}"
put "$BUNDLE_LOCAL" -o "${BUNDLE_REMOTE}"
bye
EOF

# Local cleanup
rm -f "$BUNDLE_LOCAL"

echo ""
echo "Uploaded: ${BUNDLE_REMOTE}"
echo ""
echo "To promote in chamber (from an ETX shell):"
echo "    sync-promote"
echo "  or manually:"
echo "    cd ~/architecture && git fetch '${BUNDLE_REMOTE}' main:refs/heads/main && git reset --hard main"
