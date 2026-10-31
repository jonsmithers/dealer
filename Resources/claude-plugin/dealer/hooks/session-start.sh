#!/bin/sh
# Claude Code SessionStart hook: tells the agent it runs in a Dealer pane, which one, and that the
# `dealer` skill drives Dealer. Its stdout becomes session context; it prints nothing outside
# Dealer and always exits 0.

# Only in a Dealer pane, and not when the user opted out (DEALER_CLAUDE_HOOKS=0). Unlike
# dealer-hook.sh this runs for `claude -p` too: it only adds context and marks no pane.
[ -n "${DEALER_PANE_ID:-}" ] || exit 0
[ "${DEALER_CLAUDE_HOOKS:-1}" != 0 ] || exit 0

cli=dealer
command -v dealer >/dev/null 2>&1 || cli='"$DEALER_CLI"'

# `caller  pane:12 tab:4 deck:2 workspace:1 window:1`; just the pane ID if Dealer can't answer.
where=$("${DEALER_CLI:-dealer}" identify 2>/dev/null | sed -n 's/^caller  *//p')
[ -n "$where" ] || where="pane:$DEALER_PANE_ID"

cat <<EOF
This session runs inside Dealer, a macOS terminal. Its own pane: $where (dealer target IDs).
\`$cli\` drives Dealer: panes, tabs, decks and workspaces, typing into them and reading their screens, background jobs.
Load the dealer skill before using it. With no -t target, its commands act on this pane.
EOF
exit 0
