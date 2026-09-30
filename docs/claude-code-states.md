# Claude Code states in a Dealer pane

This page covers what a Claude Code session goes through inside a pane, how it tells the
terminal about each state, and how that maps onto Dealer's pane states: **running**,
**waiting**, **done** and **unread** (see the README's Attention section). The research was
done on 2026-09-30 against Claude Code **2.1.285** (build afb2129).

Each fact is tagged with its source:
- **[obs]**: observed in real sessions (hook payloads logged to a file, and terminal output
  captured with `script`, with `TERM_PROGRAM=ghostty`, in a scratch project).
- **[docs]**: the official docs, linked at the end.
- **[bin]**: strings in the installed Claude Code binary. These are internal, not a contract,
  and may change between versions.

## At a glance

| Claude is… | Why | Fastest signal | Dealer state |
|---|---|---|---|
| **Working** | A turn is running: the model is streaming, or tools or subagents are running | OSC 9;4;3 progress (immediately) [obs]. `UserPromptSubmit` hook [obs] | **running** (from progress) |
| **Asking for tool permission** | A tool call needs approval | `PermissionRequest` hook (immediately) [docs]. `Notification`/`permission_prompt` hook and OSC 777 after about 6 s [obs] | **waiting** (with the recommended hooks) |
| **Asking a question** (AskUserQuestion) | Claude needs you to pick an answer | `PreToolUse` matcher `AskUserQuestion` [docs]. `Notification`/`permission_prompt` after about 6 s [bin] | **waiting** |
| **Asking to approve a plan** (ExitPlanMode) | Plan mode wants to start working | `PermissionRequest` matcher `ExitPlanMode` [docs]. Notification text "Claude Code needs your approval for the plan" [bin] | **waiting** |
| **Asking for MCP input** (elicitation) | An MCP server wants form or URL input | `Elicitation` hook [docs]. `Notification`/`elicitation_dialog` or `elicitation_url_dialog` after about 6 s [docs] | **waiting** |
| **Finished its turn** | The reply is complete and it's your move | `Stop` hook (immediately) [obs]. Progress cleared with OSC 9;4;0 [obs] | **done** |
| **Still idle after about 60 s** | You haven't typed since it finished | `Notification`/`idle_prompt`, and OSC 777 "Claude is waiting for your input" [obs] | stays **done** (not waiting) |
| **Stopped by an API error** | Rate limit, overload, auth, billing, … | `StopFailure` hook, *instead of* `Stop` [docs] | **waiting** (with the recommended hooks) |
| **Interrupted** (Esc) | You stopped it | No hook: `Stop` does not fire [docs] | none (you're already looking) |

## What makes Claude wait for you

- **Tool permission.** A tool call isn't covered by the permission mode or your allow rules.
  In `auto` mode this is rare, and in `default` mode it's common [obs]. Sandboxed commands
  that ask for network access raise a prompt too, but they don't run `PermissionRequest`
  hooks [docs].
- **AskUserQuestion.** Claude presents one to four multiple-choice questions [docs].
- **Plan approval.** ExitPlanMode, and EnterPlanMode ("Claude Code wants to enter plan mode") [docs][bin].
- **MCP elicitation.** An MCP server asks for form input or wants you to open a URL [docs].
- **Idle.** After a turn ends, Claude simply waits for your next message.
- **Errors.** A turn that ends in an API error stops and waits. "Session paused" dialogs
  (usage limits, overage consent) wait too [docs][bin].
- **Trust dialog.** The first launch in an untrusted folder shows a trust dialog. No hooks run
  until you accept it [docs].

## How it signals the terminal on its own (no hooks)

When `TERM=xterm-ghostty` or `TERM_PROGRAM=ghostty`, which is always true in a Dealer pane
because libghostty sets both, Claude Code picks the ghostty behavior [bin][obs]:

- **Window title (OSC 0).** While working, the title reads `◐ <session title>` alternating
  with `◑` (about 1 s period). It reads `✳ <session title>` while idle *or* while a dialog is
  open [obs]. Dealer shows this title on the tab and in the pane bar. You can turn it off
  with `CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1` [docs].
- **Progress (OSC 9;4).** `9;4;3` (indeterminate) is sent while a turn runs, and **stays
  set while a permission dialog is open**. `9;4;0` is sent when the turn ends [obs]. It's
  gated on `terminalProgressBarEnabled` (default true) and on ghostty ≥ 1.2.0 via
  `TERM_PROGRAM_VERSION` [docs][bin]. Background subagents keep it set after the turn ends [docs].
- **Desktop notification (OSC 777).** `ESC]777;notify;Claude Code;<message>BEL`. It's sent
  for permission prompts and elicitations (after about 6 s) and for idle (after about 60 s)
  [obs]. This is `preferredNotifChannel: "auto"` resolving to `ghostty`. Other values:
  `terminal_bell` (a bare BEL), `iterm2` (OSC 9), `iterm2_with_bell`, `kitty` (OSC 99),
  `ghostty` (OSC 777), and `notifications_disabled` [docs][bin]. The channel changes only
  the terminal alert; Notification hooks fire either way [docs].
- **Bell.** None seen in normal runs [obs].
- **`claude -p`** (print mode) writes no OSC sequences at all. Hooks still run [obs].

Taken together, **title prefix + progress** already tell the states apart with no setup [obs]:

| Title prefix | Progress | State |
|---|---|---|
| `◐` / `◑` | `9;4;3` | working |
| `✳` | `9;4;3` | dialog open (waiting on you) |
| `✳` | `9;4;0` | idle |

## Timing

- **Permission / elicitation notifications** (the hook and OSC 777): about 6 s after the
  prompt appears. Each keystroke restarts that wait in the terminal [docs][bin].
  **`PermissionRequest` is immediate** [docs].
- **`idle_prompt`**: about 60 s after the turn ends, and only if you haven't typed since. It
  isn't sent while waiting for a usage limit to reset [docs]. The threshold appears to be
  `messageIdleNotifThresholdMs` in `~/.claude.json` (default 60000). That key is undocumented [bin].
- **`Stop`, `StopFailure`, title and progress changes**: immediate [obs][docs].

## Hook payloads

Every hook receives JSON on stdin and inherits Claude's environment, so `DEALER_PANE_ID`
reaches it [docs]. The examples below were observed [obs]; `transcript_path` and `cwd` are
omitted.

```json
{"hook_event_name":"Notification","notification_type":"permission_prompt","message":"Claude needs your permission","session_id":"…"}
{"hook_event_name":"Notification","notification_type":"idle_prompt","message":"Claude is waiting for your input","session_id":"…"}
{"hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"ok","background_tasks":[],"session_crons":[],"permission_mode":"default","session_id":"…"}
{"hook_event_name":"UserPromptSubmit","prompt":"…","permission_mode":"auto","session_id":"…"}
```

Other relevant payload fields:
- `PermissionRequest`: `tool_name`, `tool_input`, `permission_suggestions` [obs].
- `StopFailure`: `error` (one of `rate_limit`, `overloaded`, `authentication_failed`,
  `billing_error`, `server_error`, `max_output_tokens`, …), `error_details` and
  `last_assistant_message` [docs].
- `Notification`: may also carry a `title` [docs].
- Other `notification_type` values: `auth_success`, `elicitation_complete`,
  `elicitation_response`, `agent_needs_input`, `agent_completed`, `quota_auto_resume_*` [docs].

## Mapping onto Dealer

| Dealer state | Set by | Cleared by |
|---|---|---|
| **running** | OSC 9;4 progress set (automatic, no setup) | progress removed (`9;4;0`); outranked by waiting/done |
| **waiting** | `dealer notify --state waiting` from hooks: `PermissionRequest`, `Notification` (`permission_prompt`, `elicitation_*`), `StopFailure` | focusing the pane |
| **done** | `dealer notify --state done` from the `Stop` hook | focusing the pane |
| **unread** | OSC 9/99/777 desktop notifications (Claude's own OSC 777 included), the bell, commands running ≥ 10 s | focusing the pane |

The README's "Claude Code hooks" section has the recommended configuration.

### Gaps

1. **Without hooks, a waiting Claude is labelled *unread*, not *waiting*.** Claude's own
   OSC 777 lands as `unread` (a quiet grey dot since #7), and only after about 6 s. Until
   then the pane shows *running*, because progress stays set while the dialog is open. Hooks
   fix this.
2. **The catch-all `Notification` hook mislabelled idle as waiting.** `idle_prompt` fires
   about 60 s after every finished turn, so a *done* pane turned blue a minute later.
   *Fixed in #7:* the README hook now matches only
   `permission_prompt|elicitation_dialog|elicitation_url_dialog`.
3. **`permission_prompt` is late** (about 6 s). *Fixed in #7:* the README adds a
   `PermissionRequest` hook, which fires immediately. A hook that prints nothing makes no
   decision, so the normal prompt still shows [docs].
4. **API errors never marked the pane.** `StopFailure` replaces `Stop`. *Fixed in #7:* the
   README maps it to *waiting*.
5. **AskUserQuestion's first seconds.** `PermissionRequest` is not documented to fire for
   AskUserQuestion, so it relies on the ~6 s `permission_prompt`. A `PreToolUse` hook
   matching `AskUserQuestion` would make it immediate; I haven't verified this live.
6. **After you answer a prompt from another pane or window**, e.g. via `dealer send-text`,
   the pane stays *waiting* until focused. A `UserPromptSubmit` or `PostToolUse` hook calling
   `dealer notify --state none` would clear it. This isn't recommended by default; it adds a
   hook call per tool.

### Proposed (not done)

- **Zero-config waiting detection:** in `GhosttyRuntime`, treat a title starting with `✳`
  while progress is still set as *waiting*. Alternatively, map OSC 777 notifications from
  "Claude Code" whose body is a known prompt text to *waiting*. Both key on Claude-specific
  strings ([bin]/[obs], not a contract), so this should be opt-in or clearly isolated.
- **New Agent Pane with built-in hooks:** launch `claude --settings '<json>'` with the hooks
  above, so preset panes get accurate states without the user editing
  `~/.claude/settings.json`. cmux does the same, and also sets
  `"preferredNotifChannel": "notifications_disabled"` so the terminal alert doesn't
  duplicate the hook [obs].
- **Watch** the dormant OSC 21337 "tab status" sequence in the binary
  (`status=Idle|Working|Waiting`). It's disabled in 2.1.285. If it ships, Dealer could read
  the state directly [bin].

## Sources

Claude Code 2.1.285. `docs.claude.com/en/docs/claude-code/*` now redirects to `code.claude.com/docs/en/*`:
- Hooks reference: https://code.claude.com/docs/en/hooks
- Hooks guide: https://code.claude.com/docs/en/hooks-guide
- Settings reference: https://code.claude.com/docs/en/settings-reference
- Terminal configuration: https://code.claude.com/docs/en/terminal-config
- Environment variables: https://code.claude.com/docs/en/env-vars

libghostty sets `TERM_PROGRAM`/`TERM_PROGRAM_VERSION`: `~/git/ghostty/src/termio/Exec.zig`.
