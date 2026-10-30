# Program status reports (OSC 7501, #89) for Dealer's own scripts. Sourced, not run; POSIX sh, and
# zsh-safe (record-demo.sh sources it too).
#
#   . "$(dirname "$0")/lib/program-status.sh"
#   program_status_init dealer-bundle bundle         # app (stable program id), record id
#   trap 'program_status_exit $?' EXIT               # done on exit 0, error otherwise
#   trap 'exit 130' INT; trap 'exit 143' TERM        # so a ⌃C also ends in `error`
#   program_status working "swift build" "release build"   # STATE [TITLE [MSG [PROGRESS]]]
#   program_status done "Bundled" "build/Dealer.app"
#
# The traps belong in the script itself, at top level: zsh runs an EXIT trap set inside a function
# when that function returns. In this file, write `${var}:key`, never `$var:key`: zsh reads `:a`,
# `:t` and friends after a bare `$var` as history modifiers.
#
# Reports go to /dev/tty, never stdout, which may be a pipe or a file. Nothing is written when
# there's no terminal, under CI, or with DEALER_PROGRAM_STATUS=0 (a knob for these scripts, not a
# Dealer setting). Terminals that don't know OSC 7501 ignore it, as they ignore every unknown OSC,
# so scripts don't probe for support first (the spec's `OSC 7501 ; ?` + `CSI c` dance would mean
# reading the reply from the tty, for nothing).
#
# Spec: https://www.superlogical.com/rex/docs/build/program-status. `app` and `id` must be names
# (letters, digits, `_ . + -`; ids may join names with `/`). Each report replaces its record whole.

PROGRAM_STATUS_APP=
PROGRAM_STATUS_ID=
PROGRAM_STATUS_LAST=
PROGRAM_STATUS_STEP=
PROGRAM_STATUS_ON=0

# program_status_init APP ID: who reports, and whether anything will be written.
program_status_init() {
  PROGRAM_STATUS_APP=$1
  PROGRAM_STATUS_ID=$2
  PROGRAM_STATUS_LAST=
  PROGRAM_STATUS_STEP=
  PROGRAM_STATUS_ON=0
  [ "${DEALER_PROGRAM_STATUS:-1}" = 0 ] && return 0
  [ -n "${CI:-}" ] && return 0
  # Opening /dev/tty fails without a controlling terminal (launchd, ssh -T, cron).
  if ( : > /dev/tty ) 2>/dev/null; then PROGRAM_STATUS_ON=1; fi
  return 0
}

# One line of text, safe for the spec: control characters become spaces (newlines included),
# at most $2 bytes without splitting a UTF-8 character, then base64.
_program_status_text() {
  printf '%s' "$1" | tr '\000-\037\177' ' ' | head -c "$2" | iconv -c -f UTF-8 -t UTF-8 2>/dev/null | base64 | tr -d '\n'
}

# program_status STATE [TITLE [MSG [PROGRESS]]]
# STATE: idle, working, done, blocked, error or clear. For `blocked`, set PROGRAM_STATUS_KIND
# (permission, question or auth) for that one call. PROGRESS: 0-100, for working and blocked.
program_status() {
  PROGRAM_STATUS_LAST=$1
  [ "$1" = working ] && PROGRAM_STATUS_STEP=${2:-}
  [ "$PROGRAM_STATUS_ON" = 1 ] || return 0
  _ps_body="state=$1"
  [ -n "$PROGRAM_STATUS_ID" ] && _ps_body="${_ps_body}:id=$PROGRAM_STATUS_ID"
  [ -n "$PROGRAM_STATUS_APP" ] && _ps_body="${_ps_body}:app=$PROGRAM_STATUS_APP"
  [ -n "${PROGRAM_STATUS_KIND:-}" ] && [ "$1" = blocked ] && _ps_body="${_ps_body}:kind=$PROGRAM_STATUS_KIND"
  [ -n "${4:-}" ] && _ps_body="${_ps_body}:progress=$4"
  [ -n "${2:-}" ] && _ps_body="${_ps_body}:title=$(_program_status_text "$2" 192)"
  [ -n "${3:-}" ] && _ps_body="${_ps_body}:msg=$(_program_status_text "$3" 2048)"
  # A whole sequence is at most 4096 bytes; the limits above keep a report well under it.
  { printf '\033]7501;%s\033\\' "$_ps_body" > /dev/tty; } 2>/dev/null || true
  return 0
}

# program_status_exit STATUS [DONE_MSG]: for the script's EXIT trap. A failure always ends in
# `error` (never a stale `working`); a success ends in `done` unless the script already said so.
program_status_exit() {
  case $1 in
    0) case $PROGRAM_STATUS_LAST in
         done|error|idle|clear|'') ;;
         *) program_status done "Finished" "${2:-}" ;;
       esac ;;
    *) [ "$PROGRAM_STATUS_LAST" = error ] ||
         program_status error "Failed${PROGRAM_STATUS_STEP:+: $PROGRAM_STATUS_STEP}" "exit status $1" ;;
  esac
}
