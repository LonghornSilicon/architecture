#!/usr/bin/env bash
# ============================================================================
# lambda-detach.sh
# ----------------------------------------------------------------------------
# Single-function library: gui_detach.
#
# Encapsulates the "launch a GUI tool on a compute node, fork it cleanly,
# log its output to scratch, leave a PID file" pattern. Replaces the csh-only
# `<tool> < /dev/null >& /tmp/tool.log &` idiom from the chamber reference.
#
# Source this file (after lambda-env.sh has run) and call:
#     gui_detach <tag> <tool> [args...]
#
# Example:
#     gui_detach stratus.mate.gui stratus_ide -prj project.tcl
#
# Side effects:
#   - Writes "$LAMBDA_LOGS/<tag>.<UTC-timestamp>.log"
#   - Writes "/tmp/lambda-<tag>.<pid>.pid" containing the child PID
#   - Prints PID + log path + watch hint to stdout
# ============================================================================

# shellcheck disable=SC2034  # consumed by sourcing scripts
LAMBDA_DETACH_LOADED=1

gui_detach() {
    local tag="${1:?gui_detach: missing tag}"; shift
    local tool="${1:?gui_detach: missing tool}"; shift

    : "${LAMBDA_LOGS:?LAMBDA_LOGS not set; source tools/lib/lambda-env.sh first}"

    # Preflight: tool must exist
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "ERROR: '$tool' not in PATH. Module not loaded?" >&2
        echo "Hint:  module list   (check what's loaded)" >&2
        echo "       lambda-diagnose   (full chamber probe)" >&2
        return 1
    fi

    # Preflight: X11 must be available (every GUI tool needs DISPLAY)
    if [[ -z "${DISPLAY:-}" ]]; then
        echo "ERROR: \$DISPLAY is not set; X11 forwarding required for GUI tools." >&2
        echo "Hint:  ssh -X (or -Y) into the chamber, then re-qsh." >&2
        echo "       Test forwarding:  xclock &" >&2
        return 1
    fi

    local timestamp
    timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
    local log_file="$LAMBDA_LOGS/${tag}.${timestamp}.log"
    local pid_file="/tmp/lambda-${tag}.$$.pid"

    # nohup + redirect: stdin from /dev/null avoids tty-output suspension,
    # &> sends both stdout and stderr to the log, & backgrounds the process.
    nohup "$tool" "$@" </dev/null &>"$log_file" &
    local pid=$!

    echo "$pid" > "$pid_file"

    cat <<EOF
Launched: $tool $*
  PID:    $pid
  log:    $log_file
  pidfile:$pid_file

To watch progress: tail -f $log_file
To stop:           kill $pid
EOF
}
