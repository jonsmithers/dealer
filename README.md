# Dealer

A small macOS terminal built on **libghostty** (Ghostty's embedding API) and Swift/AppKit,
implementing the *Panes and Decks* layout model:

```
Window
└─ Decks    split side by side or stacked; each has its own tab strip
   └─ Tabs    one active per deck
      └─ Panes  split inside a single tab; hidden when the tab is
```

A **pane** is owned by a tab. A **deck** owns tabs. Splitting always makes panes;
**promote** turns a pane into a deck, **fold** turns it back.

## Build & run

Prerequisites: macOS 14+, Xcode command-line tools, a Ghostty checkout at `~/git/ghostty`,
`brew install zig@0.15` (Homebrew's default zig 0.16 can't build Ghostty), and ideally
`/Applications/Ghostty.app` for shell integration and terminfo.

```sh
scripts/build-ghosttykit.sh      # once: builds GhosttyKit.xcframework from ~/git/ghostty into vendor/
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

## Keys

| Key | Action |
|---|---|
| ⌘T | New tab in the focused deck |
| ⌘D / ⌘⇧D | Split right / down (makes panes) |
| ⌘W / ⌥⌘W | Close pane / tab |
| ⌘1…⌘8, ⌘9 | Go to tab / last tab in the focused deck |
| ⌘⇧] / ⌘⇧[ | Next / previous tab |
| ⌘⇧P | **Promote**: pane → deck, hoisted to the window edge on its side, keeping its width |
| ⌘⇧F | **Fold**: deck → pane, back where it came from |
| ⌘⇧↑ | Select parent split (then ⌘⇧P promotes the whole group) |
| ⌘⌥←→↑↓ | Move focus by geometry, across decks |
| ⌘⇧↩ | Zoom: fill the deck, press again to fill the window, again to restore |
| ⌃⌘= | Equalize splits |
| ⌘N | New window |
| ⌃1…⌃9 | Go to workspace N |
| ⌃⌘N / ⌃⌘W | New / close workspace |
| ⌃⌘] / ⌃⌘[ | Next / previous workspace |
| ⌃⌘S | Show / hide the workspace sidebar |
| ⌘⇧U | Jump to the next pane that needs attention |
| ⌥⌘A / ⌥⇧⌘A | New agent pane / in a new git worktree |

Double-click a tab to rename it; middle-click or hover × to close it.

Workspaces are listed in a sidebar on the left: number, name, attention dot, and a dim line
with the focused pane's agent state, cwd and branch. Click a row to switch, double-click to
rename, right-click for a menu, middle-click to close, drag to reorder, "New Workspace" to add.
It shows by itself once a window has two workspaces; the toggle right of the traffic lights (or
⌃⌘S) hides or shows it, and that choice is remembered per window. The Workspace menu also moves
the focused pane, tab or deck to another workspace or a new one, and reorders workspaces.

## Dragging

Drag a pane by its bar (shown once a tab has two panes; ⌥-drag grabs its parent split),
or drag a tab:

| Drop on | Pane | Tab |
|---|---|---|
| Edge of another pane | re-split beside it | rejoins as a split |
| Centre of another pane | swap the two | — |
| A tab strip | becomes its own tab (works across decks) | reorder / move to that deck |
| Window edge (past the decks) | promote to a new deck | becomes a new deck |
| A workspace in the sidebar | moves to that workspace as a tab | same |
| "New Workspace" in the sidebar | moves to a new workspace, which you follow | same |
| Hover a tab | switches to it after a short delay | same |

## Attention (coding agents)

A pane that wants you gets a coloured ring, and its tab gets a dot. Amber means an agent is
waiting for input; blue means something finished or rang. The dot also shows on the deck's
tab strip and the workspace. Focusing the pane clears it. **⌘⇧U** (Window > Jump to Next
Unread) goes to the most urgent pane in any window. When Dealer isn't the key window, it
also posts a macOS notification (bundled app only), and clicking it focuses the pane.

Sources:
- the bell (BEL);
- desktop notifications from OSC 9, OSC 99 and OSC 777;
- a shell command that ran for 10s or more finishing (needs Ghostty shell integration);
- `dealer notify` from inside the pane (the control socket/CLI, #5). Each shell gets
  `DEALER_PANE_ID`, so `dealer notify` targets its own pane by default.

### Claude Code hooks

Add this to `~/.claude/settings.json` (or a project's `.claude/settings.json`). The
`DEALER_PANE_ID` guard makes the hooks a no-op in other terminals.

```json
{
  "hooks": {
    "Notification": [
      { "hooks": [{ "type": "command",
        "command": "[ -n \"$DEALER_PANE_ID\" ] && dealer notify --state waiting --title 'Claude Code' --body \"$(jq -r '.message // empty')\" || true" }] }
    ],
    "Stop": [
      { "hooks": [{ "type": "command",
        "command": "[ -n \"$DEALER_PANE_ID\" ] && dealer notify --state done --title 'Claude Code' --body 'Finished' || true" }] }
    ]
  }
}
```

`Notification` fires when Claude needs permission or has been idle waiting for input. It
reads the hook's JSON from stdin, which is why `jq` pulls out `.message`. `Stop` fires when
Claude finishes its turn. States are `waiting`, `done`, `unread` and `none` (clears the pane).
Inside Dealer panes, `dealer` is on `PATH` (the bundle's `Contents/Resources/bin` is appended).
Codex and other agents work the same way through their own hook or notify settings. Anything
that prints an OSC 9 notification (`printf '\e]9;done\a'`) also works with no setup.
The hooks need the bundled app (`scripts/bundle.sh`); a bare `.build/debug/Dealer` has no `dealer` on `PATH`.

### Status and agent panes

The pane bar shows the pane's status on the right: agent state, cwd and git branch, e.g.
`waiting · ~/git/dealer · main`. The tab's tooltip shows the same line. The states are:
- **running**: the program is reporting progress with OSC 9;4. Claude Code does this while it works.
- **waiting** / **done**: from attention.

The branch is read from `.git/HEAD`, and worktrees work too.

**Shell > New Agent Pane** (⌥⌘A) splits the focused pane and starts an agent in the new pane.
**New Agent Pane in Worktree** (⌥⇧⌘A) first runs `git worktree add -b agent-N` into
`<repo>.worktrees/agent-N` and starts the agent there. The command is `claude` by default.
Change it with `defaults write dev.smithers.dealer agentCommand 'codex'` or `DEALER_AGENT_COMMAND`.
It is typed into the pane's shell, so you're back at a prompt when the agent exits.

## Scripting: `dealer`

`dealer` drives a running Dealer over a Unix socket: `create` panes/tabs/decks/workspaces
(`--side`, `--size`, `--cwd`, `--command`, `--title`, `--no-focus`), `send-text`, `focus`,
`resize`, `rename`, `identify`, `list --json` (IDs, cwd, foreground process and PIDs),
`find --process RE`, and `notify`. Commands are synchronous and IDs are stable. See
[docs/cli.md](docs/cli.md) for the reference and the `b` / `focus-nvim` recipes.

## Session restore

Quitting saves the full window → deck → tab → pane tree (sizes, working directories,
tab names, focus) to `~/Library/Application Support/Dealer/session.json`; the next launch
restores it. Closing the last window by hand starts fresh next time. Sessions from the old
MyTerm location are copied over on first launch.

## Self-test

```sh
swift build && DEALER_SELFTEST=quit .build/debug/Dealer
```

Replays the design's walkthrough (tabs, panes, rearranging, decks, deep promote, fold,
group promote, focus, zoom, swap, tab moves, snapshot round-trip) against a live window
and asserts the tree after each step.

## Layout

- `GhosttyRuntime.swift` – `ghostty_app_t`, config, runtime callbacks (clipboard, actions, close)
- `SurfaceView.swift` – NSView hosting a `ghostty_surface_t`: keys + IME, mouse, sizing, focus
- `Model.swift` – generic binary split `Node`, `Pane`, `Tab`, `Deck`
- `TerminalWindowController.swift` – all structural operations and layout
- `DragController.swift` – pane/tab drag & drop targets
- `Views.swift` – deck, tab strip, pane bar, dividers, overlays
- `Session.swift` – save/restore
- `Workspace.swift` / `WorkspaceSidebar.swift` – workspaces, and the collapsible workspace sidebar + its titlebar toggle
- `Theme.swift` – chrome colors derived from the ghostty config (light/dark), metrics, fonts, motion
- `ControlServer.swift` / `ControlHandler.swift` / `ControlNotify.swift` – control socket, request handler, `dealer notify`
- `SelfTest*.swift` – self-test, one file per feature section
- `AgentStatus.swift` – pane status line (agent state, cwd, git branch)
- `AgentLaunch.swift` – New Agent Pane presets
- `Attention.swift` – per-pane attention (bell/OSC/agent), badges, jump to next unread, macOS notifications
