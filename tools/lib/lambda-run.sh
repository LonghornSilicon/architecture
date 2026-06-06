#!/usr/bin/env bash
# ============================================================================
# lambda-run.sh
# ----------------------------------------------------------------------------
# Shared launcher helpers. Source AFTER lambda-env.sh (depends on $LAMBDA_WORK,
# the module pins, and the bootstrapped `module` function). All functions are
# idempotent. None call `exit` — callers handle non-zero returns.
#
# Provides:
#   lambda_require_tool <MODULE_SPEC> <binary>
#       Load the module and verify the binary resolves. The chamber's /apps tree
#       is autofs, so a successful `module load` returns 0 even when the install
#       isn't on this node — what matters is whether the binary lands on PATH
#       once the load + path-scan triggers the automount. Emits the canonical
#       compute-node hint on failure (the v0.3-debug-session lesson).
#
#   lambda_rundir <block> <tool> <mode>
#       Print the path of the run directory and ensure it exists. `gui` and
#       `shell` modes use a stable `interactive/` dir (no timestamp clutter);
#       `batch` mints a UTC `<run-id>` dir and repoints the `latest` symlink to
#       it. Never clobbers; preserves prior runs for reproducibility + sweeps.
#
#   lambda_publish_release <block> <src-path> <dst-name>
#       Atomically promote a tool output into $LAMBDA_WORK/<block>/release/ as
#       <dst-name>, and append a MANIFEST line (UTC, tool, run-id, git sha).
#       This is the contract between stages — the next tool reads from release/,
#       not from a sibling tool's run dir, so a messy run doesn't poison the
#       handoff. Returns 0 on success, 1 if src missing.
# ============================================================================

# shellcheck disable=SC2034  # consumed by sourcing scripts
LAMBDA_RUN_LOADED=1

# ---- lambda_require_tool ---------------------------------------------------
# Usage: lambda_require_tool <MODULE_SPEC> <binary-name>
# Example: lambda_require_tool "$INNOVUS_MODULE" innovus
lambda_require_tool() {
    local module_spec="${1:?lambda_require_tool: missing MODULE_SPEC}"
    local binary="${2:?lambda_require_tool: missing binary name}"

    if ! type module >/dev/null 2>&1; then
        cat >&2 <<EOF
ERROR: 'module' command not available in this shell.
Hint:  run chamber-diagnose to see the module-system bootstrap fallbacks
       tried by lambda-env.sh. If running on a non-standard chamber, set
       LAMBDA_MODULE_INIT=/path/to/init/bash in ~/.longhorn/lambda.env.
EOF
        return 1
    fi

    # module load returns 0 even when the underlying install is missing on
    # this node (the autofs trap from the 2026-06-06 debug session).
    if ! module load "$module_spec" 2>/dev/null; then
        cat >&2 <<EOF
ERROR: 'module load $module_spec' failed.
Possible causes:
  - Wrong version pinned in tools/lib/lambda-env.sh
  - Per-user override needed: echo 'export <TOOL>_MODULE=$module_spec' >> ~/.longhorn/lambda.env
Check available versions:  module avail ${module_spec%%/*}
EOF
        return 1
    fi

    # The real test: did the binary actually land on PATH? On an autofs chamber,
    # PATH-scanning the just-appended /apps/<TOOL>/bin is what triggers the
    # automount. If that fails, we're almost certainly on a login node that
    # doesn't carry the digital tools.
    if ! command -v "$binary" >/dev/null 2>&1; then
        local host="${HOSTNAME:-$(hostname 2>/dev/null || echo unknown)}"
        local node_class="unknown"
        case "$host" in
            ae[0-9]*ut[0-9]*) node_class="LOGIN node" ;;
            ip-*)             node_class="compute node" ;;
        esac
        cat >&2 <<EOF
ERROR: '$binary' not resolvable after loading $module_spec.
Host:  $host  ($node_class)
       /apps/<TOOL> is autofs — a module load + PATH touch is what mounts it.
       This usually means you're on a LOGIN node (carries only Virtuoso +
       vManager), not a compute node (which carries the digital + sim tools).

Fix:   qsh -q normal.q -now n -V       # get a compute shell, then retry.
       (Use 'lambda-diagnose' for a full chamber probe.)
EOF
        return 1
    fi

    return 0
}

# ---- lambda_rundir ---------------------------------------------------------
# Usage: lambda_rundir <block> <tool> <mode>
#   block:  one of $LAMBDA_BLOCKS
#   tool:   genus | innovus | xcelium | verisium | ...  (the run-dir bucket)
#   mode:   gui | shell    -> $LAMBDA_WORK/<block>/<tool>/interactive
#           batch          -> $LAMBDA_WORK/<block>/<tool>/<utc-runid>, latest -> here
# Prints the run-dir path on stdout; creates it; returns 1 on missing args.
lambda_rundir() {
    local block="${1:?lambda_rundir: missing block}"
    local tool="${2:?lambda_rundir: missing tool}"
    local mode="${3:?lambda_rundir: missing mode}"
    : "${LAMBDA_WORK:?LAMBDA_WORK not set; source tools/lib/lambda-env.sh first}"

    local tool_root="$LAMBDA_WORK/$block/$tool"
    local rundir

    case "$mode" in
        gui|shell)
            rundir="$tool_root/interactive"
            ;;
        batch)
            local run_id
            run_id="$(date -u +%Y%m%d-%H%M%S)"
            rundir="$tool_root/$run_id"
            ;;
        *)
            echo "ERROR: lambda_rundir: unknown mode '$mode' (expected gui|shell|batch)" >&2
            return 1
            ;;
    esac

    if ! mkdir -p "$rundir" 2>/dev/null; then
        echo "ERROR: cannot create run dir: $rundir" >&2
        return 1
    fi

    # Repoint `latest` for batch runs (atomic-ish via temp symlink + rename).
    if [[ "$mode" == "batch" ]]; then
        local latest_link="$tool_root/latest"
        local tmp_link="$tool_root/.latest.$$"
        ln -sfn "$(basename "$rundir")" "$tmp_link" 2>/dev/null && \
            mv -f "$tmp_link" "$latest_link" 2>/dev/null || \
            ln -sfn "$(basename "$rundir")" "$latest_link" 2>/dev/null
    fi

    printf '%s\n' "$rundir"
}

# ---- lambda_publish_release ------------------------------------------------
# Usage: lambda_publish_release <block> <src-path> <dst-name> [<tool>] [<run-id>]
# Promotes <src-path> to $LAMBDA_WORK/<block>/release/<dst-name> and appends a
# manifest line. Returns 1 on missing src.
lambda_publish_release() {
    local block="${1:?lambda_publish_release: missing block}"
    local src="${2:?lambda_publish_release: missing src}"
    local dst_name="${3:?lambda_publish_release: missing dst-name}"
    local tool="${4:-?}"
    local run_id="${5:-?}"
    : "${LAMBDA_WORK:?LAMBDA_WORK not set}"
    : "${LAMBDA_ROOT:?LAMBDA_ROOT not set}"

    if [[ ! -e "$src" ]]; then
        echo "ERROR: lambda_publish_release: source not found: $src" >&2
        return 1
    fi

    local release_dir="$LAMBDA_WORK/$block/release"
    local dst_path="$release_dir/$dst_name"
    local manifest="$release_dir/MANIFEST"

    mkdir -p "$release_dir" 2>/dev/null || {
        echo "ERROR: cannot create release dir: $release_dir" >&2; return 1; }

    # cp -L to dereference symlinks; -f to overwrite the prior release.
    if ! cp -fL "$src" "$dst_path" 2>/dev/null; then
        echo "ERROR: failed to publish $src -> $dst_path" >&2
        return 1
    fi

    local utc git_sha
    utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    git_sha="$(cd "$LAMBDA_ROOT" 2>/dev/null && git rev-parse --short HEAD 2>/dev/null || echo unknown)"
    printf '%s  %-8s  %-25s  %-15s  sha=%s\n' \
        "$utc" "$tool" "$dst_name" "$run_id" "$git_sha" >> "$manifest"

    echo "Published: $dst_path"
}

# ---- lambda_finalize_rundir -----------------------------------------------
# Usage: lambda_finalize_rundir <run-dir> <exit-code>
# Writes <run-dir>/STATUS in a fixed parseable format:
#     PASS  <UTC-ISO>  rc=0
#     FAIL  <UTC-ISO>  rc=<n>
# Best-effort: never fails the run if the write doesn't succeed (caller already
# has the real exit code; STATUS is observability, not control flow). Always
# returns 0.
#
# Why STATUS is separate from `latest`:
#   - `latest` symlink = most-recent *invocation* (verisium needs this to open
#     a crashed run's waves.shm for debugging).
#   - `STATUS` file    = pass/fail of THAT invocation.
#   - `release/MANIFEST` = which run produced the current published artifact.
# Three orthogonal signals; downstream code can answer any of the three
# questions without reading the tool log.
lambda_finalize_rundir() {
    local run_dir="${1:?lambda_finalize_rundir: missing run-dir}"
    local rc="${2:?lambda_finalize_rundir: missing exit-code}"
    [[ -d "$run_dir" ]] || return 0

    local utc verdict
    utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [[ "$rc" == "0" ]]; then verdict="PASS"; else verdict="FAIL"; fi
    printf '%s  %s  rc=%s\n' "$verdict" "$utc" "$rc" > "$run_dir/STATUS" 2>/dev/null || true
    return 0
}
