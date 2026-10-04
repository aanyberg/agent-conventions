#!/usr/bin/env bash
# mark-blocked.sh: block one item and tell the backlog source why.
#
#   mark-blocked.sh <item> --tried "<what was tried>" --why "<why it failed>" --needs "<input needed>"
#
# GitHub source: comment plus `blocked` label on the issue.
# File source: `BLOCKED: <reason>` on the item, written by the final status PR.
# The item leaves its batch and the loop continues with the rest.
set -u
BL_SELF=mark-blocked
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
bl_paths || bl_die "not inside a git repository"
bl_state_ok || bl_die "no usable state; run preflight.sh first"

item="${1:-}"
[ -n "$item" ] || bl_die "usage: mark-blocked.sh <item> --tried \"...\" --why \"...\" --needs \"...\""
shift
tried=""
why=""
needs=""
while [ $# -gt 0 ]; do
  case "$1" in
    --tried) tried="${2:-}"; shift 2 ;;
    --why) why="${2:-}"; shift 2 ;;
    --needs) needs="${2:-}"; shift 2 ;;
    *) bl_die "unknown argument: $1" ;;
  esac
done
[ -n "$why" ] || bl_die "--why is required: say why the item cannot be finished"
[ -n "$needs" ] || bl_die "--needs is required: say what input a human must provide"

"$BL_SCRIPT_DIR/state.sh" record blocked "$item" --tried "${tried:-nothing yet}" --why "$why" --needs "$needs" || exit 1
printf 'BLOCKED: %s\n  Tried:  %s\n  Why:    %s\n  Needs:  %s\nRun next.sh.\n' "$(bl_ref "$item")" "${tried:-nothing yet}" "$why" "$needs"
