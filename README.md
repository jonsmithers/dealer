<p align="center">
  <img src="docs/icon.png" width="128" height="128" alt="Dealer app icon">
</p>

<h1 align="center">Dealer</h1>

A small macOS terminal built on **libghostty** and Swift/AppKit, implementing the *Panes and Decks*
layout model:

```
Window
└─ Workspaces  switched in sidebar or ⌃1–9
   └─ Decks      split horizontal or vertical, each with its own tab strip
      └─ Tabs      one active per deck, switched with ⌘1–9
         └─ Panes   split horizontal or vertical inside a single tab
```

A **workspace** owns a set of decks. A **deck** owns tabs. A tab owns **panes**. **Split** creates a
new pane in the current tab. **Promote** turns a pane into a deck. **Fold** turns it back. Closing
the last tab closes its deck, the last deck its workspace, and the last workspace the window.

## Features overview

<details open>
<summary><b>1. Panes and Decks layout</b>: drop tabs into side-by-side and stacked splits, drag a pane to the window edge for a new deck (it keeps its content while you switch tabs next to it), pull a pane out as a tab in another deck, drop a tab between two tabs of another deck</summary>

https://github.com/user-attachments/assets/c35df457-2717-4e97-82d9-3162dfdca204
</details>

<details>
<summary><b>2. Workspaces</b>: one per project or worktree, each with its own color; click to switch, drag tabs between them, gather them into collapsible groups</summary>

https://github.com/user-attachments/assets/f6185ee8-040d-4e4e-883f-43f0e6c7df3a
</details>

<details>
<summary><b>3. Agents & Attention</b>: agent-working spinner, a progress ring for builds, blue accent when something is finished/waiting, red when something has failed. Visible from any workspace</summary>

https://github.com/user-attachments/assets/070ddcb9-3746-4fe6-bb2d-f227ef344e50

The states here are driven with `dealer notify`, typed into the pane; that's exactly what Dealer's
automatic Claude Code hooks call (see [Attention](#attention-coding-agents)). This is not a live
Claude session: a real one shows its own permission prompt in the pane.
</details>

<details>
<summary><b>4. Go to Pane</b>: ⌘⇧A, type a few letters, jump to any pane in any workspace; ⏎ on an empty query goes back</summary>

https://github.com/user-attachments/assets/cba40ade-7518-4b9e-99d2-ec52713af3bf
</details>

Demo videos are recorded with `scripts/record-demo.sh`.

> [!WARNING]
> **Unstable.** Updates may change any aspect of dealer without notice or migration.

> [!WARNING]
> **Coding-agent support currently covers [Claude Code](https://claude.com/claude-code) only.**
> Codex, Gemini CLI and other agents aren't supported yet. For now they run like any other program:
> the generic marks (the bell, desktop notifications, failed commands) apply, but the working,
> waiting and done marks don't.

> [!WARNING]
> Dealer is written in Swift. But Jon (the human who prompted Claude) doesn't know Swift. It's all
> vibe-coded 🙈. Please do not expect him to be a competent steward of this codebase. Blame Claude
> for everything, not Jon.

## Build & run

Prerequisites: macOS 14+, Xcode command-line tools (full Xcode isn't needed; see
`scripts/ghostty-build/README.md`), zig 0.17, and a Ghostty checkout at the commit pinned in
`scripts/ghostty.version`. The easiest place for it is next to this repo:

```sh
git clone https://github.com/ghostty-org/ghostty.git ../ghostty
git -C ../ghostty checkout --detach "$(tail -1 scripts/ghostty.version)"
```

`build-ghosttykit.sh` looks for the checkout in `--ghostty PATH` / `$GHOSTTY_SRC`, then `../ghostty`,
then asks. Besides the framework, it writes Ghostty's shell integration, themes and terminfo from
the same build to `vendor/ghostty-resources`, and `bundle.sh` ships them inside `Dealer.app`
(licenses in `Contents/Resources/THIRD-PARTY-NOTICES.txt`), so you don't need Ghostty.app
installed. With an older `vendor/` that lacks them, Dealer borrows them from an installed Ghostty.app
(`/Applications`, `~/Applications`, or wherever Launch Services finds it). To use another
directory, set `DEALER_GHOSTTY_RESOURCES_DIR`. It refuses to build a different commit unless you pass `--any-version`, because
libghostty's embedding API changes often. `--dry-run` shows what it would do.

The pin is enforced against the framework you actually have in `vendor/` (#35):
`scripts/check-ghostty.sh` compares the commit recorded in the library with the pin, and
`scripts/bundle.sh` refuses to bundle on a mismatch (`GHOSTTY_ANY_VERSION=1` overrides).
The self-test fails on a mismatch, and at launch the app shows a red banner if the linked
Ghostty isn't the pinned one.

```sh
scripts/build-ghosttykit.sh      # once: builds GhosttyKit.xcframework and ghostty-resources into vendor/
scripts/bundle.sh                # swift build + wraps build/Dealer.app (release by default; `debug` for a debug build)
open build/Dealer.app            # run it
```

Optionally, put `dealer` (the scripting CLI) on your `PATH` for use in other terminals.
It's already on `PATH` inside Dealer's own panes:

```sh
ln -s "$PWD/build/Dealer.app/Contents/Resources/bin/dealer" ~/.local/bin/dealer
```

The link survives rebuilds; point it at `/Applications/Dealer.app/...` if you copy the app there.

For development, `swift build && .build/debug/Dealer` runs the app unbundled. That build has no
macOS notifications and no `dealer` on `PATH` (use `.build/debug/Dealer <subcommand>` instead).
Every normal launch restores and overwrites your session (see *Session restore*). Use
`DEALER_SELFTEST=1 .build/debug/Dealer` to get a throwaway window that leaves the session alone.

Your normal Ghostty config (`~/.config/ghostty/config`) is loaded, and window chrome takes its
colors from your Ghostty theme (background/foreground, `unfocused-split-*`, `split-divider-color`).
`background-opacity` below 1 makes the window translucent, chrome included (tab strips, bars,
sidebar and gaps take the same opacity; text and outlines stay solid), and `background-blur`
blurs what's behind it. On macOS 26, `background-blur = macos-glass-regular` or
`macos-glass-clear` puts Liquid Glass behind the window (older macOS gets a plain blur instead).
The chrome is shaded just far enough from the terminal's background that the active tab stands out;
`[colors] chrome_contrast` in [settings.toml](#settings) sets how far (default 1.35, lower is subtler).
After editing it, **⌘⇧,** (Dealer › Reload Configuration) applies the change live, as in Ghostty:
terminals and chrome re-theme without restarting anything (see [Settings](#settings)).

**Clipboard access by programs** (OSC 52, and kitty's clipboard protocol) follows Ghostty's
`clipboard-read` and `clipboard-write` settings: `allow`, `deny` or `ask`. Like Ghostty, reading
defaults to **ask** and writing to **allow**. With `ask`, Dealer asks in a sheet on the pane's
window, naming the pane, and only once that window is in front; Deny sends the program nothing.
`deny` never asks. ⌘⇧, applies a change.

**Pasting** text that would run commands as it lands (it contains a newline, and the program
hasn't turned on bracketed paste) asks first, with a preview: Ghostty's
`clipboard-paste-protection`, on by default (`clipboard-paste-bracketed-safe` decides whether
bracketed paste counts as safe). Cancel pastes nothing.

New splits, tabs, workspaces and windows start in the focused pane's current directory, as its
shell reports it (Ghostty's shell integration; without it, the directory the pane started in).
Ghostty's `split-inherit-working-directory`, `tab-inherit-working-directory` and
`window-inherit-working-directory` (workspaces count as windows) turn that off. A new pane then
starts in your `working-directory`. Restored sessions keep each pane's saved directory, and
`dealer create` starts in its target's directory unless you pass `--cwd`.

## Keys

| Key | Action |
|---|---|
| ⌘T | New tab in the focused deck |
| ⌘D / ⌘⇧D | Split right / down (makes panes) |
| ⌘W / ⌥⌘W | Close pane / tab |
| ⌘1…⌘8, ⌘9 | Go to tab / last tab in the focused deck |
| ⌘⇧] / ⌘⇧[ | Next / previous tab |
| ⌘⇧P | **Promote**: pane → deck, hoisted to the window edge on its side, keeping its width (a whole tab gets an even share instead) |
| ⌘⇧F | **Fold**: deck → pane, back where it came from |
| ⌘⇧↑ | Select parent split (then ⌘⇧P promotes the whole group) |
| ⌘⌥←→↑↓ | Move focus by geometry, across decks |
| ⌘⇧↩ | Zoom: fill the deck, press again to fill the window, again to restore |
| ⌃⌘= | Equalize splits |
| ⌘N / ⇧⌘N | New workspace / new window |
| ⌃1…⌃9 | Go to workspace N |
| ⌃⌘W | Close workspace |
| ⌃⌘] / ⌃⌘[ | Next / previous workspace |
| ⌘B | Show / hide the workspace sidebar (sidebar mode only) |
| ⌘⇧U | Jump to the next pane that needs attention |
| ⌥⌘A / ⌥⇧⌘A | New agent pane / in a new git worktree |
| ⌘⇧A | **Go to Pane**: search panes in every window by title, tab or workspace name, and focus one |
| ⌘, | Open Dealer's settings file |
| ⌘⇧, | **Reload Configuration**: the ghostty config (colors, font, …) and settings.toml, live |

These menu shortcuts win over Ghostty keybinds, so a `keybind` in your Ghostty config on one of
these keys never fires. Ghostty has no default ⌘B binding, but a `keybind = cmd+b=…` of yours is
shadowed by the sidebar toggle.

**Go to Pane** (⌘⇧A, Shell › Go to Pane…) opens a search over every pane in every window. Type
part of a pane's title, or of its tab's or workspace's name (the letters in order, not
necessarily together); title matches come first. Each row shows the title, `workspace · tab`, the
directory, the window when there's more than one, and the pane's attention dot or working spinner.
↑/↓ and return pick a pane, which focuses it and brings its window, workspace and tab forward; esc
or a click outside dismisses. With nothing typed it lists the panes you used most recently first,
so ⌘⇧A ↩ goes back to the previous pane.

Double-click a tab to rename it; middle-click or hover × to close it. A pane's bar (shown once a tab has two panes) has the same hover ×, which closes the pane like ⌘W.

Workspaces are listed in a sidebar on the left: number, name, attention dot, and a dim line
with the focused pane's agent state, cwd and branch. Click a row to switch, double-click to
rename, right-click for a menu, middle-click to close, drag to reorder, "New Workspace" to add.
It shows by itself once a window has two workspaces; the toggle right of the traffic lights (or
⌘B) hides or shows it, and that choice is remembered per window. The Workspace menu also moves
the focused pane, tab or deck to another workspace or a new one, and reorders workspaces.

To put the switcher in the top bar instead, as numbered pills right of the traffic lights, pick
**Workspace › Workspace Switcher › In Top Bar** (or `switcher = "top"` under `[workspaces]` in
[settings.toml](#settings); `sidebar` is the default). The change applies to every open window at
once. Pills do the same things as rows: click, double-click to rename, right-click, middle-click
to close, drag to reorder, "+" to add, and take pane/tab drops. In top-bar mode the sidebar and
its toggle are gone and ⌘B is disabled; each window's sidebar choice is kept for when you switch
back.

### Tabs in the titlebar

By default (`[window] tabs_in_titlebar = true` in [settings.toml](#settings)), the tab strips of decks
along the window's top edge move up into the titlebar row (like Safari's compact tabs), and those
decks start right under the titlebar. Each strip stays over its own deck. Decks lower down keep
their strips. The strips start after the traffic lights and the sidebar toggle, or after the
workspace pills in top-bar mode. A deck too narrow for that keeps its strip. Empty titlebar space,
including the space after a strip's tabs, still drags the window, and double-clicking it zooms or
minimizes per System Settings. Tabs there drag and drop as usual. The change applies live.

### Tab style

Tabs are "connected" by default: the active tab joins its deck's content below it, with no seam,
so it reads as one surface with its terminal (also from the titlebar row), and is underlined in its
deck's color where it meets the terminal. On a translucent window
tabs stay opaque. For the older look, rounded pill tabs floating in
the strip over a separate content card, set `[tabs] style = "pill"` in [settings.toml](#settings).
The change applies live.

### Colors

Right-click a workspace (sidebar row or pill) or a tab for **Workspace Color** / **Tab Color**:
preset swatches, **Custom…** (the system color panel) or **None**. A workspace's color shows only on
its entry in the switcher (its sidebar row, or its pill in top-bar mode), as a chip and a faint
tint. It doesn't appear in the deck area or on tabs. A colored tab gets a faint tint and an underline in its color, which replaces
the deck's color on that tab. Uncolored tabs stay neutral, except for the active tab's underline in
its deck's color. A tab's color moves with the tab;
a workspace's color stays with the workspace. Colors are saved with the session. From a script:
`dealer color -t workspace:2 teal`, `dealer color --tab '#e06c75'`, `dealer color --workspace none`.
In settings.toml, `[colors] auto_assign = true` colors each new workspace with the next unused
swatch, and `palette = ["#…", …]` replaces the swatches.

## Dragging

Drag a pane by its bar (shown once a tab has two panes; ⌥-drag grabs its parent split),
or drag a tab:

| Drop on | Pane | Tab |
|---|---|---|
| Edge of another pane | re-split beside it | rejoins as a split |
| Centre of another pane | swap the two | — |
| A tab strip | becomes its own tab (works across decks) | reorder / move to that deck |
| Window edge (past the decks) | promote to a new deck, sized evenly with the decks along that edge | same |
| A workspace in the sidebar (or its pill) | moves to that workspace as a tab | same |
| "New Workspace" in the sidebar (or the "+" pill) | moves to a new workspace, which you follow | same |
| Hover a tab | switches to it after a short delay | same |

## Attention (coding agents)

When an agent is **waiting** for input, its pane gets an accent-blue ring. The tab and the
workspace containing it get a blue outline and a blue dot, so you can see where you're needed
from anywhere. When something **failed**, the same ring, outline and dot appear in **red**,
and the dot carries a `!` so it doesn't rely on color alone. That covers a `dealer run` job
exiting non-zero, a Claude turn ending in an API error, and a shell command exiting non-zero
while you're not looking. **Done** (an agent finished its turn, a job succeeded: your move) looks
exactly like waiting by default: blue ring, outline and dot. **Unread** (something rang or a long
command finished) is deliberately quieter: a muted grey dot on the tab and workspace, with no ring
or outline. Both looks are settings (`[attention] done` and `unread`, below). The blue is a lighter shade
on dark ghostty themes and a deeper one on light themes, and so is the red. Focusing the pane
clears all of it. A tab or workspace shows its most urgent pane: failed, then waiting, then done,
then unread. **⌘⇧U** (Window > Jump to Next Unread) goes to the most urgent pane in any window,
in the same order. When Dealer isn't the active app, or the screen is locked, a mark also posts a
macOS notification (bundled app only), and clicking it focuses the pane. While Dealer is in front,
the marks alone carry it, in every window. When the mark clears, or the pane closes, its
notification is removed from Notification Center.

When attention clears, its ring, outline and dot **fade out** over about a second instead of
vanishing, so you can see which pane called you. Arriving via ⌘⇧U or a notification holds the
color for half a second first. The state itself clears at once: ⌘⇧U and `dealer` see it gone
immediately. With macOS **Reduce Motion** on, there's no fade (the hold stays).

| State | Set by | Default look | Setting |
|---|---|---|---|
| **failed** | a `dealer run` job exits non-zero; a Claude turn ends in an API error (`[agent] errors_as_failed`, default on); a shell command exits non-zero (`[attention] failed_commands`, default on); `dealer notify --state failed` | red outline | not configurable |
| **waiting** | a Claude permission prompt, question or plan approval; an MCP server asking for input; `dealer notify --state waiting` | blue outline | not configurable |
| **done** | Claude finishes a turn; a `dealer run` job succeeds (marks the job pane, which lingers before it closes; never your own pane); `dealer notify --state done` | blue outline | `done = "outline"` (default) or `"dot"` |
| **unread** | the bell; a desktop notification (OSC 9, 99 or 777) from any program; a shell command that succeeded after running 10 s or more; `dealer notify` with no `--state` | grey dot | `unread = "dot"` (default) or `"outline"` |

Most urgent first: failed > waiting > done > unread, whatever the looks.

Sources:
- the bell (BEL);
- desktop notifications from OSC 9, OSC 99 and OSC 777;
- a shell command finishing, with Ghostty shell integration: a non-zero exit marks *failed*
  (`[attention] failed_commands`, default on), and a success that ran for 10 s or more marks
  *unread*;
- `dealer notify` from inside the pane (the control socket/CLI, #5). Each shell gets
  `DEALER_PANE_ID`, so `dealer notify` targets its own pane by default.

A mark is skipped only while you're looking at the pane: it's focused and showing, its window is
key, Dealer is active and the screen is unlocked. A source that only raises (bell, OSC, command
finished) never lowers a stronger state. A mark clears when you see it: focusing the pane while
you're at the machine, or coming back to the window (it becoming key, or unlocking the screen)
with the pane focused. Focus that moves while you're away (a pane closing, `dealer focus` from a
script) keeps the mark until you're back. Notification permission is re-read whenever Dealer
comes forward, so allowing notifications in System Settings needs no relaunch.

**Why didn't Dealer notify me?** Set `[notifications] log = true` in [settings.toml](#settings) (live,
no restart). Dealer then appends one line per decision to `/tmp/dealer-notifications.log`: each
input (hook event, `dealer notify`, `dealer run` result, bell, OSC notification, command finished),
whether the pane's mark was set or *skipped*, whether a notification was posted or *suppressed*, and
the reason for every "no". It also logs clicks, what cleared a mark (focus, ⌘⇧U, a click, the window
becoming key), each notification *withdrawn* when its mark cleared or its pane closed, and the
notification permission status. Lines name the pane by the ID `dealer list`
shows, plus its workspace and tab:

```
2026-10-12T21:29:58.015-04:00 claude:stop attention:set pane=2 ws="api" tab="claude" reason="none → done" title="Claude Code" body="Finished"
2026-10-12T21:29:58.016-04:00 claude:stop notification:suppressed pane=2 ws="api" tab="claude" reason="app active and the pane's window is key (not the focused pane, but its window); the mark shows in the window" title="Claude Code" subtitle="claude" body="Finished"
2026-10-12T21:29:57.998-04:00 bell attention:skipped pane=3 ws="api" tab="build" reason="wanted unread: already waiting, which outranks it (this source only raises); no notification"
```

Titles and bodies are truncated to 120 characters; no terminal contents or environment. Past ~5 MB
the file is renamed to `.1` (one old file kept). macOS deletes `/tmp` files untouched for about
3 days. `dealer diagnose` says whether the log is on and how big it is. Claude hook calls the plugin
filters out itself (outside a Dealer pane, nested `claude -p`, `DEALER_CLAUDE_HOOKS=0`) never reach
Dealer, so they aren't logged.

### Claude Code hooks (automatic)

Every `claude` started in a Dealer pane reports *waiting* and *done* with no setup. That
covers `claude` typed at the prompt, an alias, an absolute path, and New Agent Pane. Dealer
ships a small Claude Code plugin (`Contents/Resources/claude-plugin/dealer`) and names it in
each pane's `CLAUDE_CODE_PLUGIN_DIRS`. If you already set that variable, Dealer appends to it.
Nothing is written to your `~/.claude` settings. The plugin's hooks:

- `PermissionRequest`: *waiting* the moment Claude asks to use a tool or approve a plan. It
  makes no decision; you still answer the prompt in the pane.
- `Notification` (`permission_prompt`, `elicitation_dialog`, `elicitation_url_dialog`):
  *waiting*. It leaves out `idle_prompt`, which would turn a *done* pane into *waiting*
  about 60 s after every turn.
- `Stop`: *done*.
- `StopFailure` (API errors such as rate limits or auth): *failed* (red). Set
  `[agent] errors_as_failed = false` to get *waiting* instead.

The hooks do nothing outside Dealer (no `DEALER_PANE_ID`). They also do nothing for
non-interactive runs (`claude -p`, the SDK), so an agent that runs `claude -p` from its Bash
tool doesn't mark its pane *done* mid-turn. A user `"disableAllHooks": true` turns them off
too. Needs Claude Code 2.1.280 or later; older versions ignore the variable.

**Turning it off**
- Everywhere: `inject_hooks = false` under `[agent]` in [settings.toml](#settings). New shells
  pick it up.
- For one shell or one launch: `export DEALER_CLAUDE_HOOKS=0`, or
  `DEALER_CLAUDE_HOOKS=0 claude`.
- If your organization's managed settings set `disableSideloadFlags`, Claude Code refuses to
  start with `CLAUDE_CODE_PLUGIN_DIRS` set. Dealer leaves the variable out when
  `/Library/Application Support/ClaudeCode/managed-settings.json` says so. Policy delivered by
  MDM or the server can't be detected, so turn the setting off.

**Manual recipe.** Use this for a `claude` that doesn't inherit a pane's environment, such as
one inside a tmux server started outside Dealer, or for Claude Code older than 2.1.280. Add it
to `~/.claude/settings.json`. The `DEALER_PANE_ID` guard makes it a no-op in other terminals.
If the plugin also loads, both fire, which is harmless: the same state twice is a no-op.

```json
{
  "hooks": {
    "PermissionRequest": [
      { "hooks": [{ "type": "command",
        "command": "[ -n \"$DEALER_PANE_ID\" ] && dealer notify --state waiting --title 'Claude Code' --body \"Permission: $(jq -r '.tool_name // empty')\" || true" }] }
    ],
    "Notification": [
      { "matcher": "permission_prompt|elicitation_dialog|elicitation_url_dialog",
        "hooks": [{ "type": "command",
        "command": "[ -n \"$DEALER_PANE_ID\" ] && dealer notify --state waiting --title 'Claude Code' --body \"$(jq -r '.message // empty')\" || true" }] }
    ],
    "Stop": [
      { "hooks": [{ "type": "command",
        "command": "[ -n \"$DEALER_PANE_ID\" ] && dealer notify --state done --title 'Claude Code' --body 'Finished' || true" }] }
    ],
    "StopFailure": [
      { "hooks": [{ "type": "command",
        "command": "[ -n \"$DEALER_PANE_ID\" ] && dealer notify --state failed --title 'Claude Code error' --body \"$(jq -r '.error // empty')\" || true" }] }
    ]
  }
}
```

States are `failed`, `waiting`, `done`, `unread` and `none` (clears the pane). Without any hooks, Claude
Code still sends its own OSC 777 notification (shown as *unread*) and OSC 9;4 progress
(*running*). [docs/claude-code-states.md](docs/claude-code-states.md) covers every state,
signal and timing, plus the research behind the automatic hooks.

Inside Dealer panes, `dealer` is on `PATH` (the bundle's `Contents/Resources/bin` is appended),
and `DEALER_CLI` holds its absolute path. Codex and other agents work the same way through their
own hook or notify settings. Anything that prints an OSC 9 notification
(`printf '\e]9;done\a'`) also works with no setup.

### Status and agent panes

The pane bar shows the pane's status on the right: agent state, cwd and git branch, e.g.
`waiting · ~/git/dealer · main`. The tab's tooltip shows the same line. The states are:
- **running**: the program is reporting progress with OSC 9;4. Claude Code does this while it works.
  A running pane also puts Claude's working mark (#64, #73; the animated spark from claude.ai) in front of the title on its **tab** and on its
  **workspace**'s sidebar row or pill, so you can see at a glance which tabs and workspaces have an
  agent working right now — including ones you aren't looking at. It's drawn in the terminal's
  foreground colour and pulses brighter and dimmer, never in an attention colour, and a pane that's
  *waiting* on you doesn't show it even though Claude keeps progress set while a dialog is open.
  With macOS **Reduce Motion** on, the mark stands still at full brightness.
- **waiting** / **done**: from attention.

**Keep the display awake while agents work** (#69): with `[power] caffeinate = true` in
[settings.toml](#settings) (off by default; applies live), Dealer holds a macOS power assertion
whenever any tab or workspace in any window shows the working mark, and for 30 s after the
last one stops, so the screen doesn't sleep under a long agent run. A coffee cup at the right end
of every window's titlebar shows while it's held; its tooltip explains it: how many agents are
working, when the display will sleep again, and how to turn it off.
It's an IOKit assertion (what `caffeinate -d` takes), listed under Dealer in
`pmset -g assertions`, and gone if Dealer quits or crashes. It doesn't stop a manual lock or
closing the lid.

The branch is read from `.git/HEAD`, and worktrees work too.

**Shell > New Agent Pane** (⌥⌘A) splits the focused pane and starts an agent in the new pane.
**New Agent Pane in Worktree** (⌥⇧⌘A) first runs `git worktree add -b agent-N` into
`<repo>.worktrees/agent-N` and starts the agent there. The command is `claude` by default.
Change it with `command = "codex"` under `[agent]` in [settings.toml](#settings), or the
`DEALER_AGENT_COMMAND` environment variable (which wins).
It is typed into the pane's shell, so you're back at a prompt when the agent exits.

## Settings

Dealer's own settings live in `~/.config/dealer/settings.toml` (or `$XDG_CONFIG_HOME/dealer/`).
Terminal settings (font, colors, keybinds) stay in your ghostty config. **Dealer › Open Settings
File…** (⌘,) opens it, creating it from the commented
[docs/settings.example.toml](docs/settings.example.toml) if it doesn't exist yet.

```toml
[agent]
command = "claude"       # what New Agent Pane runs; DEALER_AGENT_COMMAND overrides it
inject_hooks = true      # load Dealer's Claude Code plugin in new panes

[workspaces]
switcher = "sidebar"     # or "top" (pills in the titlebar)

[window]
tabs_in_titlebar = true  # put top-edge decks' tab strips in the titlebar row

[tabs]
style = "connected"      # or "pill": the active tab joins its deck's content, or floats as a pill

[colors]
auto_assign = false      # color new workspaces with the next unused swatch
palette = ["#e06c75", "#98c379", "#61afef"]   # replaces the preset swatches
chrome_contrast = 1.35   # how far the chrome stands off the terminal: 1.0 (none) to 2.5

[attention]              # see the table under Attention for every state
done = "outline"         # or "dot": done looks like waiting (blue outline) or gets a muted dot
unread = "dot"           # or "outline"
failed_commands = true   # a shell command exiting non-zero marks the pane failed

[jobs]                   # `dealer run` (see Scripting below)
placement = "split"      # or "tab" (a background tab next to yours)
size = 12                # job split height: rows, "30%" or "0.3"
close_on_success = true  # failed jobs always stay open
linger = 5               # seconds a succeeded job's pane stays, marked done, before it closes

[notifications]
log = false              # log every attention/notification decision to /tmp/dealer-notifications.log

[power]
caffeinate = false       # keep the display awake while agents work (+30 s), with a titlebar cup
```

- Changes apply live: Dealer watches the file (editors that save by replacing it work too).
  **Dealer › Reload Configuration** (⌘⇧,) forces a re-read.
- The same command reloads the **ghostty config**: the terminals pick up the new colors and font,
  and Dealer's chrome (tab strips, decks, pane bars, the sidebar or pills, the unfocused-pane veil)
  re-themes at once. Shells keep running. Ghostty's own `reload_config` keybind does the same. A
  ghostty config with errors is not applied: the previous one stays in effect, and the banner
  lists the problems ("Open Ghostty Config" opens the file).
- A mistake never blocks launch. A bad value falls back to its default, and a banner in each
  window (plus a log line) lists the problems with line numbers.
- Menu toggles (like Workspace Switcher) write back to the file, changing only their own value
  and keeping your comments and layout. With no file yet, the toggle creates it from the example.
- Settings made with `defaults write dev.smithers.dealer …` before this file existed
  (`agentCommand`, `workspaceSwitcher`, `agentInjectHooks`) are still read when the file doesn't
  set that key. Dealer doesn't delete them.

Environment variables:

| Variable | Effect |
|---|---|
| `DEALER_AGENT_COMMAND` | Overrides `[agent] command` |
| `DEALER_CLAUDE_HOOKS=0` | Turns off Dealer's Claude Code hooks for one shell or one `claude` launch (`[agent] inject_hooks` turns them off everywhere) |
| `DEALER_SOCKET`, `DEALER_PANE_ID` | Set by Dealer in every pane; `dealer` uses them to find the app and its own pane (see [docs/cli.md](docs/cli.md)) |

## Scripting: `dealer`

`dealer` drives a running Dealer over a Unix socket: `create` panes/tabs/decks/workspaces
(`--side`, `--size`, `--cwd`, `--command`, `--title`, `--no-focus`), `send-text`, `focus`,
`resize`, `rename`, `identify`, `list --json` (IDs, cwd, foreground process and PIDs),
`find --process RE`, and `notify`. Commands are synchronous and IDs are stable. See
[docs/cli.md](docs/cli.md) for the reference and the `focus-nvim` recipe.

**Background jobs:** `dealer run <cmd>` runs a command without taking focus.
- **Where:** in the workspace that best fits your directory (the one with the deepest pane
  directory containing `$PWD`; yours on ties), as a short pane below that pane or a background tab,
  per `[jobs] placement`. If no workspace fits, it gets a new workspace named after the directory.
  stderr says which happened.
- **Title:** `RUN <cmd>`.
- **Success:** the job pane is titled `DONE <cmd>` and gets the *done* mark, plus a macOS
  notification if Dealer isn't in front. It lingers for `[jobs] linger` seconds (default 5), then
  closes. With `--keep` it stays. Your own pane is never marked.
- **Failure:** it stays open as a shell, titled `FAILED (status) <cmd>` and marked *failed*, so ⌘⇧U
  takes you there.
- **Notification:** `✓ <cmd>` or `✗ <cmd>`, then the job's workspace name.

```zsh
b() { dealer run -- "$@"; }               # b open ~/Desktop/Screenshot\ 1.png
b_str() { dealer run --quiet -- "$@"; }   # same, without the "done" mark
```

Several arguments are quoted word by word, so paths with spaces survive. A single argument is a
shell string, so `b 'make && make test'` and pipelines work. `--here` skips the routing. Details are in
[docs/cli.md](docs/cli.md#background-jobs-dealer-run-replaces-b--b_str).

## Memory diagnostics

Dealer using a lot of memory? While it's high, choose **Help › Capture Memory Diagnostics…** (or run
`dealer diagnose`) and attach the report it writes to `~/Library/Logs/Dealer/` to an issue. It holds
counts and sizes only. [docs/diagnostics.md](docs/diagnostics.md) lists what's in it and what's
normal: each pane's renderer takes tens of MB, even in a background tab.

## Session restore

Quitting saves the full window → deck → tab → pane tree (sizes, working directories,
tab names, focus) to `~/Library/Application Support/Dealer/session.json`; the next launch
restores it. Closing the last window by hand starts fresh next time.

## Self-test

```sh
swift build && DEALER_SELFTEST=quit .build/debug/Dealer
```

Replays the design's walkthrough (tabs, panes, rearranging, decks, deep promote, fold,
group promote, focus, zoom, swap, tab moves, snapshot round-trip) against a live window
and asserts the tree after each step.

<!-- vim: set tw=100: -->
