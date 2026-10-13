#!/bin/sh
# Claude Code hook -> `dealer notify` (issue #12). Usage: dealer-hook.sh <event>; hook JSON on stdin.
# Prints nothing and always exits 0, so it never makes a permission decision or blocks Claude.

# Only in a Dealer pane, only for interactive sessions (a nested `claude -p` that an agent runs from
# its Bash tool has CLAUDE_CODE_ENTRYPOINT=sdk-cli and must not mark the pane), and not when the
# user opted out for this shell or launch (DEALER_CLAUDE_HOOKS=0).
[ -n "${DEALER_PANE_ID:-}" ] || exit 0
[ "${CLAUDE_CODE_ENTRYPOINT:-cli}" = cli ] || exit 0
[ "${DEALER_CLAUDE_HOOKS:-1}" != 0 ] || exit 0

input=$(cat)
field() { printf '%s' "$input" | /usr/bin/plutil -extract "$1" raw -o - - 2>/dev/null; }

case "${1:-}" in
    permission)   state=waiting; body="Permission: $(field tool_name)" ;;
    notification) state=waiting; body=$(field message) ;;
    stop)         state=done;    body="Finished" ;;
    # An API error is a failure (red, #29); `[agent] errors_as_failed = false` makes it waiting.
    stop-failure) state=failed; [ "${DEALER_CLAUDE_ERROR_STATE:-failed}" = waiting ] && state=waiting
                  body="Error: $(field error)" ;;
    *) exit 0 ;;
esac

# --source only labels the call in Dealer's notification log ([notifications] log, #56).
"${DEALER_CLI:-dealer}" notify --state "$state" --title "Claude Code" --body "$body" --source "claude:$1" >/dev/null 2>&1
exit 0
