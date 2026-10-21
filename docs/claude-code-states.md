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
| **Stopped by an API error** | Rate limit, overload, auth, billing, … | `StopFailure` hook, *instead of* `Stop` [docs] | **failed** (red, #29; `[agent] errors_as_failed = false` → waiting) |
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
  open [obs]. Dealer shows this title on the tab and in the pane bar, minus a leading `◐ ` / `◑ `
  (#75): it draws its own working spinner, so the glyph only took space. The idle `✳ ` stays.
  Claude Code's title can be turned off with `CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1` [docs].
- **Progress (OSC 9;4).** `9;4;3` (indeterminate) is sent while a turn runs, and **stays
  set while a permission dialog is open**. `9;4;0` is sent when the turn ends [obs]. It is sent
  **once** per turn, not refreshed: an 85 s turn (a 40 s model wait, then a 45 s tool call) sent
  one `9;4;3` and one `9;4;0` [obs 2.1.305, #83]. So Dealer's progress timeout keeps it while
  Claude is still the foreground process group. It's
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

| Dealer state | Set by | Default look | Cleared by |
|---|---|---|---|
| **running** | OSC 9;4 progress set (automatic, no setup) | "running" in the pane bar, plus an animated working mark on the pane's tab and its workspace's switcher entry (#64, `RunningSpinner.swift`; standing still under Reduce Motion). Claude's own mark only when the pane's foreground process is Claude Code (or its title shows `◐`/`◑`); other programs that send OSC 9;4 (cargo, zig, other agents) get a turning arc, or a ring when they report a percentage (#81) | progress removed (`9;4;0`); outranked by waiting/done |
| **failed** | `dealer notify --state failed` from the `StopFailure` hook (#29, `[agent] errors_as_failed`); also `dealer run` failures and shell commands exiting non-zero | red outline (not configurable) | focusing the pane |
| **waiting** | `dealer notify --state waiting` from hooks: `PermissionRequest`, `Notification` (`permission_prompt`, `elicitation_*`). Automatic since #12 (bundled plugin) | blue outline (not configurable) | focusing the pane |
| **done** | `dealer notify --state done` from the `Stop` hook. Automatic since #12 | blue outline, like waiting (#61; `[attention] done = "dot"` for a muted dot) | focusing the pane |
| **unread** | OSC 9/99/777 desktop notifications (Claude's own OSC 777 included), the bell, successful commands that ran ≥ 10 s | muted dot (`[attention] unread = "outline"` to outline it) | focusing the pane |

Since #12 these hooks load automatically in every Dealer pane; see
[Injecting the hooks automatically](#injecting-the-hooks-automatically-12). The README's
"Claude Code hooks" section keeps a manual recipe for other launch paths.

### Gaps

1. **Without hooks, a waiting Claude is labelled *unread*, not *waiting*.** Claude's own
   OSC 777 lands as `unread` (a quiet grey dot by default), and only after about 6 s. Until
   then the pane shows *running*, because progress stays set while the dialog is open. Hooks
   fix this, and since #12 they're on by default. Title-based detection (#11) was closed as
   not planned in favor of #12, so Claude Code older than 2.1.280 still needs the manual recipe.
2. **The catch-all `Notification` hook mislabelled idle as waiting.** `idle_prompt` fires
   about 60 s after every finished turn, so a *done* pane became *waiting* a minute later
   (back then *done* was a grey dot, so it visibly turned blue; since #61 *done* is outlined
   blue by default, but the state would still be wrong).
   *Fixed in #7:* the README hook now matches only
   `permission_prompt|elicitation_dialog|elicitation_url_dialog`.
3. **`permission_prompt` is late** (about 6 s). *Fixed in #7:* the README adds a
   `PermissionRequest` hook, which fires immediately. A hook that prints nothing makes no
   decision, so the normal prompt still shows [docs].
4. **API errors never marked the pane.** `StopFailure` replaces `Stop`. *Fixed in #7:* the
   README maps it to *waiting*; since #29 it's *failed* (red), configurable with
   `[agent] errors_as_failed`.
5. **AskUserQuestion's first seconds.** `PermissionRequest` is not documented to fire for
   AskUserQuestion, so it relies on the ~6 s `permission_prompt`. A `PreToolUse` hook
   matching `AskUserQuestion` would make it immediate; I haven't verified this live.
6. **After you answer a prompt from another pane or window**, e.g. via `dealer send-text`,
   the pane stays *waiting* until focused. A `UserPromptSubmit` or `PostToolUse` hook calling
   `dealer notify --state none` would clear it. This isn't recommended by default; it adds a
   hook call per tool.

### Proposed (not done)

- **Zero-config waiting detection without hooks:** treat a title starting with `✳` while
  progress is still set as *waiting*, or map Claude's known OSC 777 texts to *waiting*. Both key
  on Claude-specific strings ([bin]/[obs], not a contract). Filed as #11 and closed as not
  planned ("Superseded by #12"). It would only add value for Claude Code < 2.1.280, where the
  plugin variable is ignored, and for the first instant before `PermissionRequest` fires.
- ~~New Agent Pane with built-in hooks~~: superseded by #12, which covers every `claude` in a
  pane, not just New Agent Pane.
- **Watch** the dormant OSC 21337 "tab status" sequence in the binary
  (`status=Idle|Working|Waiting`). It's disabled in 2.1.285. If it ships, Dealer could read
  the state directly [bin].

## Injecting the hooks automatically (#12)

Every `claude` started in a Dealer pane gets Dealer's hooks with no user setup. The research
was done on 2026-10-01/02. Claude Code observations are from 2.1.285 (`-p` and interactive runs
with a temporary `CLAUDE_CONFIG_DIR`, so the user's `~/.claude` was never touched); the final
real-session check ran on 2.1.287.

### What cmux does

Read in the user's checkout at `7d78b6e4cb` (2026-09-06). Upstream `5fbbc0c844` (2026-09-30)
has the same design with a larger wrapper (about 2,300 lines vs 1,636).

- **A bash wrapper, `Resources/bin/cmux-claude-wrapper`, exposed as `claude` in two ways:**
  - a per-terminal shim directory `…/cmux-cli-shims/<surface-uuid>/claude`, **prepended** to
    `PATH` at spawn (`Packages/macOS/CmuxTerminal/Sources/CmuxTerminal/Spawn/TerminalSurface+AgentCommandShims.swift`,
    `TerminalSurface+StartupEnvironment.swift`);
  - a `claude()` **shell function** defined by cmux's own shell integration
    (`Resources/shell-integration/cmux-{bash,zsh}-integration.*`, `_cmux_install_cli_wrapper`).
    The comment there: "Keep the bundled wrapper ahead of later PATH mutations". In other words,
    rc files that prepend `PATH` would otherwise shadow the shim. It's skipped if the user already
    has a `claude` alias or function.
- **Finding the real `claude`** (`find_real_claude`): it uses `CMUX_CUSTOM_CLAUDE_PATH` (a
  setting), else walks `PATH`, skipping its own directory, the shim directories, and anything
  that is the same file as itself (`-ef`). A re-exec guard (16 hops) breaks loops with other
  tools' `claude` shims.
- **When it injects:** only when `CMUX_SURFACE_ID` is set and the cmux socket answers, and only
  for session entry points (`should_inject_claude_hooks`). `--help`/`--version` and subcommands
  (`mcp`, `config`, `doctor`, `plugin`, `update`, …) pass through untouched. Note that `-p` *is*
  injected. It execs `claude --session-id <uuid> --settings <private temp file>`.
- **The injected settings** (`HOOKS_JSON`): `preferredNotifChannel: notifications_disabled`,
  plus hooks on SessionStart, Stop (+ feed, + async auto-name), SubagentStop, SessionEnd,
  Notification, UserPromptSubmit, PreToolUse (synchronous CronCreate guard + async status),
  PostToolUse (PushNotification bridge) and PermissionRequest (a **synchronous** approval
  "feed" with a 125 s timeout, used for cmux's own approval UI). All call `cmux hooks …`.
- **User hooks and flags:** it relies on Claude merging `--settings` additively. A user's own
  `--settings` is deep-merged with node into one file, because "with two --settings Claude
  reads only one … first-wins on <=2.1.168, last-wins on >=2.1.169". A `__cmux` marker
  lets a re-entered wrapper replace only its own block.
- **Outside cmux:** it passes straight through and scrubs `CMUX_*` and inherited Claude
  session-identity variables.
- **Opting out:** the `claudeCodeHooksEnabled` setting (default on) exports
  `CMUX_CLAUDE_INTEGRATION_DISABLED`/`CMUX_CLAUDE_HOOKS_DISABLED=1`, which make the wrapper
  completely inert. Setting `CMUX_CLAUDE_HOOKS_DISABLED=1` per launch does the same.
- **Sessions not started from a cmux shell:** `cmux claude-hook install` writes the hooks into
  `${CLAUDE_CONFIG_DIR:-~/.claude}/settings.json` (`docs/agent-hooks.md`).

### How Claude Code combines hook sources [obs 2.1.285 unless marked]

| Experiment | Result |
|---|---|
| User + project + `--settings` hooks | all three run (additive) |
| Two `--settings` flags | **both** hook sets ran. cmux's "only one is read" no longer holds for hooks on 2.1.285 |
| Identical handler in user settings and in `--settings` | runs **once** (deduplicated) |
| `CLAUDE_CODE_PLUGIN_DIRS=<plugin>` (documented, v2.1.280+) | the plugin's `hooks/hooks.json` runs, in addition to settings hooks, in `-p` and interactive sessions, with no prompt. `CLAUDE_PLUGIN_ROOT` is set |
| Same handler from a plugin and from settings | both run; a plugin's copy isn't deduplicated [docs] |
| User `disableAllHooks: true` | turns off `--settings` and plugin hooks too |
| Hook environment | `CLAUDE_CODE_ENTRYPOINT=cli` interactively, `sdk-cli` for `-p`/SDK; `CLAUDECODE=1` in both |
| Plugin settings | a plugin can only set `agent`/`subagentStatusLine`, so not `preferredNotifChannel` [docs] |
| Managed `disableSideloadFlags: true` | Claude exits if `CLAUDE_CODE_PLUGIN_DIRS` is set [docs]. Not reproducible locally: `CLAUDE_CODE_MANAGED_SETTINGS_PATH` didn't act as a managed source |

### Options considered

1. **A `claude` wrapper on PATH adding `--settings`** (cmux's approach, and the proposal in #12).
   It needs to win the PATH race. Dealer appends its `bin` directory, and rc files commonly
   prepend `~/.local/bin`, where Claude's installer puts `claude`. This user's `~/.zshrc` does
   exactly that, so a PATH shim alone is shadowed. Beating that takes a shell function from our
   own shell integration for zsh, bash and fish. Dealer relies on Ghostty's integration and has
   none. It also brings resolving the real binary, re-exec loops with other shims, and argv
   rewriting.
2. **A shell function only:** the same shell-integration cost, and it misses non-shell launches.
3. **Only New Agent Pane adds the flag:** ruled out by the user, since people type `claude`
   directly.
4. **Writing the user's `~/.claude/settings.json`** (like `cmux claude-hook install`): edits
   user files and affects `claude` outside Dealer. Kept only as the README's manual recipe.
5. **A bundled plugin named in `CLAUDE_CODE_PLUGIN_DIRS`.** This is the one chosen.

### Decision

Dealer ships `Resources/claude-plugin/dealer` (`.claude-plugin/plugin.json`,
`hooks/hooks.json`, `hooks/dealer-hook.sh`), copied into the bundle by `scripts/bundle.sh`.
`Pane.childEnvironment` sets `CLAUDE_CODE_PLUGIN_DIRS` for every pane (`ClaudeHooks.swift`),
appending to a value the user already has. It also exports `DEALER_CLI`, the absolute path of
the binary, which doubles as the `dealer` CLI. That way the hooks don't depend on `PATH`.

Why:
- It covers a plain `claude` in any pane, whatever the PATH order, shell, alias, absolute path
  or launcher.
- It never touches argv, so there's no real-binary lookup, no loops, no `--settings`
  collisions, and subcommands are unaffected.
- It's additive with the user's hooks and respects `disableAllHooks`.
- It's small enough to test end to end.

The hook script guards on `DEALER_PANE_ID` (outside Dealer: nothing), `CLAUDE_CODE_ENTRYPOINT = cli`
(a nested `claude -p` run by an agent's Bash tool doesn't mark the pane), and
`DEALER_CLAUDE_HOOKS != 0` (per-shell/per-launch opt-out). It reads JSON fields with
`/usr/bin/plutil` (no `jq` dependency), prints nothing (so it never makes a permission
decision), and always exits 0. The global off switch is `Settings.agentInjectHooks`
(`[agent] inject_hooks`, #10).

Trade-offs accepted:
- It needs Claude Code ≥ 2.1.280. Older versions ignore the variable.
- Claude's own OSC 777 can't be silenced from a plugin. It lands as *unread* with raise-only,
  so it never downgrades *waiting*/*done*.
- The manual recipe plus the plugin fire twice; the same state twice is a no-op.
- Under managed `disableSideloadFlags`, Dealer skips the variable when the file-based managed
  settings say so. MDM or server-delivered policy needs the off switch.

### #12 and title detection (#11)

#11 proposed detecting *waiting* from a `✳` title while progress is set. It was closed as not
planned ("Superseded by #12"), so only the hooks ship. For the record:
- **Title detection** needs nothing from Claude's hook system. It works on any Claude Code
  version and reacts the instant any dialog opens. It reads Claude-internal title strings,
  though, can't tell *done* from idle, and misreads an idle Claude with background subagents
  (progress stays set) as waiting.
- **Hooks (#12)** use the documented interface. They give *done* on `Stop`, *waiting* on API
  errors, and tool names in notification bodies, but only on ≥ 2.1.280 and only where the
  pane's environment reaches Claude.

If #11 is ever revived, both would go through `setAttention`, and title detection must only
clear a *waiting* it set itself.

### Inherited session variables

A running Claude Code exports session-identity variables to its children: `CLAUDECODE`,
`CLAUDE_CODE`, `CLAUDE_CODE_CHILD_SESSION`, `CLAUDE_CODE_BRIDGE_SESSION_ID`,
`CLAUDE_CODE_PARENT_SESSION_ID`, `CLAUDE_CODE_SESSION_ID`, `CLAUDE_CODE_ENTRYPOINT`,
`CLAUDE_CODE_EXECPATH` and `CLAUDE_CODE_SSE_PORT` (cmux's list). If Dealer itself is started from
inside a Claude session, its panes would inherit them, and a `claude` there behaves as a child
session: it warns "Transcript saving is off — inherited CLAUDE_CODE_CHILD_SESSION" [obs 2.1.287].
At app launch (not in CLI mode), Dealer unsets them from its own environment, which every pane
inherits (`ClaudeHooks.scrubInheritedSessionEnvironment`). A self-test step checks the app and a
pane's shell, and a real session launched from a Claude shell no longer shows the warning.
Auth-selection variables, which cmux also handles with per-key preserve rules, are left alone.

The same goes for another **terminal's** identity. A Dealer started from a cmux shell gave every
pane `CMUX_SURFACE_ID`, `CMUX_SOCKET_PATH`, and cmux's `claude` shim directory on `PATH`. The
user's `claude` launcher branched on `CMUX_SURFACE_ID` and ran `cmux claude-teams`, so Claude's hooks
reported to cmux and Dealer saw nothing (#12, reopened). At launch, Dealer now also unsets every
`CMUX_*` variable and drops `…/cmux-cli-shims/…` from `PATH` (`InheritedEnvironment.scrub`). The
self-test checks both the app and a pane's shell.

### Verification

- The self-test section `SelfTestClaudeHooks.swift` covers:
  - the plugin is valid;
  - the pane environment (sets, appends, no duplicate, off switch, sideload block, `DEALER_CLI`);
  - the hook script against a stub `dealer` (each event, plus all three guards);
  - **end to end:** a plain `claude` typed into a real pane's shell, using a stub `claude` on
    `PATH` that runs the plugin's hook from `CLAUDE_CODE_PLUGIN_DIRS`. The pane turns *waiting*
    through the real `dealer` CLI and socket.
- A real session in the bundled app (Claude Code 2.1.287, a temp config dir with no user
  settings, an unfocused pane, `--permission-mode default`, "touch a file"):
  - At the permission prompt, `PermissionRequest` produced `dealer notify --state waiting
    --body "Permission: Bash"` (exit 0), and the pane showed the blue ring, tab outline and
    "waiting".
  - After approval, `Stop` produced `--state done` (exit 0), and the pane showed "done" with
    a muted tab dot (the look at the time; since #61 *done* is outlined blue by default).
  - The permission prompt itself worked normally.
- The same plugin in a scratch interactive run also produced the ~6 s `permission_prompt`
  notification → *waiting*.

## Sources

Claude Code 2.1.285 (2.1.287 for the #12 real-session check). cmux: the user's checkout at
`7d78b6e4cb`, upstream `5fbbc0c844`. `docs.claude.com/en/docs/claude-code/*` now redirects to `code.claude.com/docs/en/*`:
- Hooks reference: https://code.claude.com/docs/en/hooks
- Hooks guide: https://code.claude.com/docs/en/hooks-guide
- Settings reference: https://code.claude.com/docs/en/settings-reference
- Terminal configuration: https://code.claude.com/docs/en/terminal-config
- Environment variables: https://code.claude.com/docs/en/env-vars

libghostty sets `TERM_PROGRAM`/`TERM_PROGRAM_VERSION`: `src/termio/Exec.zig` in ghostty-org/ghostty.
