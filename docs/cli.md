# `dealer`: scripting a running Dealer

`dealer` drives a running Dealer over a control socket: create panes, tabs, decks and
workspaces, type into them, focus, resize, rename, color, list, and notify.

## Setup

- Inside Dealer, `dealer` is already on `PATH`. Every shell gets `DEALER_SOCKET` (the socket),
  `DEALER_PANE_ID` (its own pane), and `PATH` with the bundle's `Contents/Resources/bin` appended.
- Outside Dealer (another terminal, nvim, launchd jobs), link it somewhere on your `PATH`:

  ```sh
  ln -s /Applications/Dealer.app/Contents/Resources/bin/dealer ~/.local/bin/dealer
  ```

  With no `DEALER_SOCKET` it uses `~/Library/Application Support/Dealer/dealer.sock`, and with no
  `DEALER_PANE_ID` commands act on the focused pane.
- Claude Code in a Dealer pane already knows this CLI: Dealer's bundled plugin gives it a
  `dealer` skill (`Contents/Resources/claude-plugin/dealer/skills/dealer/SKILL.md`). See the
  README's "Claude Code hooks" section.
- `dealer` is the app binary itself (`Dealer list` works too); it runs as a client and never
  launches the app.

## Model

- **Targets** (`-t/--target`, or the argument of `focus`): `pane:N` (or just `N`), `tab:N`, `deck:N`,
  `workspace:N`, `window:N`, or `focused`.
  - With no target, a command acts on the pane it runs in (`$DEALER_PANE_ID`), else the focused pane.
  - A pane command given a tab/deck/workspace/window uses the pane that would get focus there.
- **IDs** are stable for an object's lifetime. They survive promote, fold, move to tab, and moves
  between workspaces. They aren't persisted across restarts.
- **Synchronous:** every command replies after the change is applied, so `dealer focus 3; dealer
  identify` already sees pane 3 focused. No polling.
- **Errors:** exit 1 with a message on stderr (unknown ID, bad option value). Exit 2 means a usage
  error, including an option the command doesn't take (`notify --cwd` is an error, not ignored),
  and exit 3 means the socket is unreachable.

## Commands

| command | what it does |
| --- | --- |
| `identify [--caller \| --focused] [--json]` | Prints the caller's and the focused pane (with tab/deck/workspace/window IDs). `--caller`/`--focused` print just that pane ID. |
| `list [--json]` | Prints the tree window → workspace → deck → tab → pane, with IDs, focus, titles and cwd. Each pane also shows its tty, size, foreground process, and every process on its tty with PID, PPID, PGID and full argv. A workspace in a group (#80) shows `[group "NAME"]`; `--json` gives each workspace a `group` object (`id`, `name`, `collapsed`) or `null`. `--json` also gives each pane `agent_state` and a `progress` object (`reporting`, `percent`, `from_claude`, `foreground_pgid`), for working out why a pane's spinner is or isn't showing. A pane with program status records (OSC 7501, see `status`) lists each on a `status` line; `--json` gives each pane a `program_status` array of `{id, state, kind, progress, app, title, msg}` (root record first, `id` `""`; `app` inherited from the nearest ancestor). |
| `find [--process RE] [--title RE] [--cwd DIR] [--after ID \| --next]` | Prints the IDs of matching panes in tree order, one per line. `--process` matches any process's full command line on the pane's tty. `--next` rotates the list to start after the focused pane. |
| `create [pane\|tab\|deck\|workspace]` | Creates the object and prints the new pane's ID (`--json` for all IDs). Options: `--side left\|right\|up\|down`, `--size 12\|30%\|0.3` (rows/columns, a percent, or a fraction), `--cwd` (default: the target pane's cwd), `--command` (runs instead of the shell, as `$SHELL -l -c 'exec CMD'`; the pane closes when it exits), `--title`, `--name` (workspace), `--no-focus`. The login shell reads your profile (`.zprofile`, where `brew shellenv` goes) but not `.zshrc`, so a program whose directory only `.zshrc` puts on `PATH` isn't found when Dealer was opened from the Finder or Dock. For your full interactive environment, create a plain pane and `send-text` the command into its shell. |
| `send-text [--key K]... [--enter] [--paste] [--stdin] [--] [TEXT...]` | Types text as if typed, in argument order with keys interleaved. Keys: `enter`, `tab`, `esc`, `backspace`, `delete`, `up`/`down`/`left`/`right`, `home`, `end`, `pageup`, `pagedown`, `f1`–`f12`, `space`, and any letter/digit/punctuation with `ctrl+`, `alt+`, `shift+`, `cmd+` (for example `ctrl+c`). `--paste` sends the text as a (bracketed) paste instead. |
| `read [TARGET] [--scrollback] [--lines N] [--wait RE] [--timeout S]` | Prints a pane's text: the active screen (what the program shows now, also a full-screen one like nvim, wherever you have scrolled), or with `--scrollback` its history as well. Trailing spaces and blank lines are dropped; `--lines N` keeps the last N. `--wait RE` asks again every 0.2 s until the regular expression matches somewhere in the text (`^`/`$` match at lines), then prints it; after `--timeout` seconds (default 10) it prints what's there and exits 1. `send-text` replies once the keys are typed, not when output arrives, so wait for text only the output has: the typed line is on the screen too. `--json` gives `pane`, `text` and `lines`. |
| `focus [TARGET]` | Focuses the target and brings its window, workspace and tab forward, all in one call. |
| `resize [--axis width\|height] (--to 0.3\|30% \| --by +5\|-3\|+10%)` | Moves the divider of the nearest enclosing split (of that axis) of a pane, or of a deck (`-t deck:N`). `--to` sets the target's share. `--by` changes it by cells or percent. |
| `rename [--tab \| --workspace] [TITLE]` | Names a pane (or its tab or workspace, or `-t tab:N`). An empty title goes back to following the terminal. |
| `color [--tab \| --workspace] COLOR\|none` | Colors a tab or workspace (#9). COLOR is a swatch name (`red`, `orange`, `yellow`, `green`, `teal`, `blue`, `purple`, `pink`, or numbers 1… with a `[colors] palette`), a swatch number, or `#rrggbb`; `none` clears it. A workspace/window target colors the workspace; a pane/tab target colors its tab. `list --json` shows `color` on workspaces and `tab_color` on tabs. |
| `notify [--state unread\|done\|waiting\|failed\|none] [--title T] [--body B]` | Marks the pane for attention. The macOS notification shows `--title` (default: the state, e.g. "Finished"), then the pane's title (left out if it's the same), then `--body`. See the README's Attention section. |
| `status STATE [--id ID] [--kind permission\|question\|auth] [--progress N] [--app NAME] [--title T] [--msg M]` | Sets a program status record on the pane, exactly as a program's `OSC 7501` report would (#89; [the spec](https://www.superlogical.com/rex/docs/build/program-status)). STATE is `idle`, `working`, `done`, `blocked`, `error` or `clear` (removes the record `--id` and its children, or every record). Each call replaces its record whole. `--id` is a slash path (`build/test` is a child of `build`; none means the pane's root record), `--kind` is read for `blocked`, `--progress` (0–100) for `working` and `blocked`. `--title`/`--msg` are plain text. `working` spins the pane's tab, `blocked` marks it *waiting*, `done` and `error` mark it *done* and *failed*; `idle` and `clear` lower what records set. `working`/`blocked` records go at the next prompt or when the reporting process exits. A report the spec would discard (too long, bad id) is an error. |
| `close` | Closes a pane or tab without asking. |
| `run [--here] [--split \| --tab] [--size 12\|30%] [--keep] [--quiet] [--focus] [--title T] [--cwd DIR] [--] CMD...` | Runs CMD as a background job next to the caller (see below) and prints the job's pane ID. Routes to the workspace that best fits `$PWD`. One argument is a shell string; several are an argv, each word shell-quoted. |
| `diagnose [--leaks]` | Writes a memory diagnostics report to `~/Library/Logs/Dealer/` and prints its path (Help › Capture Memory Diagnostics… does the same). It holds counts and sizes only, no titles, cwds or terminal contents. `--leaks` also runs `leaks`, which is slow, pauses Dealer, and can quote leaked memory. It also says on stderr whether the notification log is on, where it is and how big. See [diagnostics.md](diagnostics.md). |
| `job-done STATUS` | Internal: the tail `run` types into the job's shell. Reports STATUS and exits with it. |

## Recipes

### Background jobs: `dealer run` (replaces `b` / `b_str`)

```zsh
b() { dealer run -- "$@"; }               # b make test: notify and close on success
b_str() { dealer run --quiet -- "$@"; }   # same, without the "done" mark on success
```

**Quoting rule.** Use `"$@"`, not `"$*"`.
- **Several arguments are an argv.** Each word is shell-quoted, so what your shell already parsed
  arrives intact: `b open ~/Desktop/Screenshot\ 2024-12-10\ at\ 3.52.12\ PM.png`, or
  `b grep -r '$HOME' '*.md'`.
- **One argument is a shell string,** used as is, so pipelines, `&&` and redirections work:
  `b 'make && make test'`, `b 'git log | head'`.
- **The catch:** a single word that should stay one word despite containing spaces (`b "my script.sh"`)
  is treated as a shell string and splits. Give it a second argument, or quote it inside the string:
  `b "'my script.sh'"`.

`dealer run` does the whole job in one synchronous call:

- **Where (route by cwd):** in the workspace that best fits `$PWD`. That's the one with a pane
  whose current directory is the deepest one containing `$PWD`.
  - On ties it prefers your own workspace, then your own pane.
  - The job goes beside that best-fit pane, even in a background workspace.
  - If no pane's directory contains `$PWD`, Dealer creates a workspace named after the directory,
    with the job as its only pane. On success it closes, workspace and all.
  - Which of the three happened is logged on stderr, for example
    `dealer run: re-using workspace 3 "api", whose pane in ~/git/api owns ~/git/api/src more deeply than this one`.
  - `--here` (or `-t TARGET`) skips routing and runs next to your own pane (or the target).
  - The match uses each pane's directory as its shell reports it (OSC 7, which needs shell
    integration), falling back to the foreground process's cwd. Workspaces have no root directory
    of their own.
- **Placement:** by default a split below the chosen pane, 12 rows tall. With
  `[jobs] placement = "tab"` (or `--tab`) it's a background tab right after that pane's tab. The
  split height comes from `[jobs] size` or `--size`. Focus never moves, unless you pass `--focus`.
- **Title:** the job *pane* is titled `RUN <cmd>`, which changes to `FAILED (status) <cmd>` (or
  `DONE <cmd>` with `--keep`). Tabs are never retitled; a `--tab` job's tab button just shows its
  only pane's title.
- **Running:** the command is typed into a normal interactive shell, so aliases, functions and
  your rc environment work, followed by a tail that reports the exit status:

  ```
   make test; "$DEALER_CLI" job-done $?
  ```

  The leading space keeps the line out of history if you `setopt HIST_IGNORE_SPACE` (zsh) or
  set `HISTCONTROL=ignorespace` (bash).
  `job-done` exits with the job's own status, so a kept success isn't marked failed by
  `[attention] failed_commands`.
- **Success:** the job pane is retitled `DONE <cmd>` and gets the *done* mark (a blue outline by
  default, like *waiting*; `[attention] done = "dot"` makes it a muted dot), plus a macOS
  notification when Dealer isn't in front. It lingers for `[jobs] linger` seconds (default 5; `0`
  closes it at once), then Dealer closes it itself (the shell never exits on its own; ghostty would
  keep a shell that exits within 250 ms of starting open as "abnormal"). Focusing or typing in it
  doesn't keep it; with `[jobs] close_on_success = false` or `--keep` it stays. The pane you ran
  `dealer run` from is never marked, on success or failure. A mark is skipped on a pane you're
  looking at. `--quiet` skips the mark and notification.
- **The notification** has two lines: `✓ <cmd>` (or `✗ <cmd>` on failure), then the job's
  workspace name. The exit status shows in the pane's title.
- **Failure:** the pane stays open at a prompt, so you can inspect and rerun. It's marked
  *failed* (a red ring and outline, #29), so ⌘⇧U (Jump to Next Unread) goes straight to it, ahead
  of anything merely waiting.
- If Dealer can't be reached when the job ends (it was restarted, say), the pane just stays open.

Shells: zsh, bash and other POSIX shells. fish doesn't have `$?`; use
`dealer create --no-focus` + `send-text` with your own tail there.

### `focus-nvim`: cycle through every pane running nvim

```sh
focus-nvim() {
  local id
  id=$(dealer find --process '(^|/)n?vim( |$)' --next | head -n1)
  [ -n "$id" ] && dealer focus "$id"
}
```

`find` searches all windows, workspaces, decks and tabs, in tree order. `--next` starts the list
just after the focused pane, so repeated calls cycle through the matches. `focus` switches
workspace and tab and raises the window in the same call.

### Route by cwd

`dealer run` routes by cwd on its own (see Background jobs above). To place something other than
a job the same way, use `dealer list --json`: every pane has a `cwd`.

## Protocol

The socket is `~/Library/Application Support/Dealer/dealer.sock`, mode 0600, and only
same-user peers are accepted. The protocol is one JSON object per line in each direction:

```
→ {"cmd":"create","caller":12,"args":{"type":"pane","side":"down","size":"12","focus":false}}
← {"ok":true,"result":{"pane":13,"tab":4,"deck":2,"workspace":1,"window":1}}
← {"ok":false,"error":"no pane 99"}
```

`args` mirror the CLI flags (`target`, `side`, `size`, `cwd`, `command`, `title`, `focus`, `items`
for send-text, `to`/`by`/`axis` for resize, and so on). See `Sources/Dealer/ControlHandler.swift`.

## Gaps

- Process info comes from `ghostty_surface_foreground_pid` and `ghostty_surface_tty_name`. The
  process list is everything on the pane's tty, read via sysctl. ghostty doesn't expose the
  shell's own PID, so it isn't reported separately; it's one of the listed processes.
- `cwd` is the shell-reported directory (OSC 7, which needs shell integration). Without it,
  `cwd` falls back to the foreground process's cwd.
- There is no `create window` yet.
- `status` records set from the CLI are tied to the process that's in the pane's foreground at the
  time, like a program's own: if that's the shell, `working`/`blocked` last until the next prompt.
