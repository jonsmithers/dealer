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
  error, and exit 3 means the socket is unreachable.

## Commands

| command | what it does |
| --- | --- |
| `identify [--caller \| --focused] [--json]` | Prints the caller's and the focused pane (with tab/deck/workspace/window IDs). `--caller`/`--focused` print just that pane ID. |
| `list [--json]` | Prints the tree window → workspace → deck → tab → pane, with IDs, focus, titles and cwd. Each pane also shows its tty, size, foreground process, and every process on its tty with PID, PPID, PGID and full argv. |
| `find [--process RE] [--title RE] [--cwd DIR] [--after ID \| --next]` | Prints the IDs of matching panes in tree order, one per line. `--process` matches any process's full command line on the pane's tty. `--next` rotates the list to start after the focused pane. |
| `create [pane\|tab\|deck\|workspace]` | Creates the object and prints the new pane's ID (`--json` for all IDs). Options: `--side left\|right\|up\|down`, `--size 12\|30%\|0.3` (rows/columns, a percent, or a fraction), `--cwd` (default: the target pane's cwd), `--command` (runs instead of the shell; the pane closes when it exits), `--title`, `--name` (workspace), `--no-focus`. |
| `send-text [--key K]... [--enter] [--paste] [--stdin] [--] [TEXT...]` | Types text as if typed, in argument order with keys interleaved. Keys: `enter`, `tab`, `esc`, `backspace`, `delete`, `up`/`down`/`left`/`right`, `home`, `end`, `pageup`, `pagedown`, `f1`–`f12`, `space`, and any letter/digit/punctuation with `ctrl+`, `alt+`, `shift+`, `cmd+` (for example `ctrl+c`). `--paste` sends the text as a (bracketed) paste instead. |
| `focus [TARGET]` | Focuses the target and brings its window, workspace and tab forward, all in one call. |
| `resize [--axis width\|height] (--to 0.3\|30% \| --by +5\|-3\|+10%)` | Moves the divider of the nearest enclosing split (of that axis) of a pane, or of a deck (`-t deck:N`). `--to` sets the target's share. `--by` changes it by cells or percent. |
| `rename [--tab \| --workspace] [TITLE]` | Names a pane (or its tab or workspace, or `-t tab:N`). An empty title goes back to following the terminal. |
| `color [--tab \| --workspace] COLOR\|none` | Colors a tab or workspace (#9). COLOR is a swatch name (`red`, `orange`, `yellow`, `green`, `teal`, `blue`, `purple`, `pink`, or numbers 1… with a `[colors] palette`), a swatch number, or `#rrggbb`; `none` clears it. A workspace/window target colors the workspace; a pane/tab target colors its tab. `list --json` shows `color` on workspaces and `tab_color` on tabs. |
| `notify [--state unread\|done\|waiting\|none] [--title T] [--body B]` | Marks the pane for attention. See the README's Attention section. |
| `close` | Closes a pane or tab without asking. |
| `run [--split \| --tab] [--size 12\|30%] [--keep] [--quiet] [--focus] [--title T] [--cwd DIR] [--] CMD...` | Runs CMD as a background job next to the caller (see below) and prints the job's pane ID. A single argument is used verbatim (`dealer run "$*"`); several are shell-quoted. |
| `job-done STATUS` | Internal: the tail `run` types into the job's shell. Exits 0 when the shell should close. |

## Recipes

### Background jobs: `dealer run` (replaces `b` / `b_str`)

```zsh
b() { dealer run -- "$*"; }               # b make test: notify and close on success
b_str() { dealer run --quiet -- "$*"; }   # same, without the "done" mark on success
```

`dealer run` does the whole job in one synchronous call:

- **Placement:** by default a split below the calling pane, 12 rows tall. With
  `[jobs] placement = "tab"` (or `--tab`) it's a background tab right after the caller's. The split
  height comes from `[jobs] size` or `--size`. Focus never moves, unless you pass `--focus`.
- **Where:** next to `$DEALER_PANE_ID` (outside Dealer: the focused pane, or `-t`), in your `$PWD`.
- **Title:** `RUN <cmd>`, which changes to `FAILED (status) <cmd>` (or `DONE <cmd>` with `--keep`).
- **Running:** the command is typed into a normal interactive shell, so aliases, functions and
  your rc environment work, followed by a tail that reports the exit status:

  ```
   make test; "$DEALER_CLI" job-done $? && exit
  ```

  The leading space keeps the line out of history if you `setopt HIST_IGNORE_SPACE` (zsh) or
  set `HISTCONTROL=ignorespace` (bash).
- **Success:** the shell exits and the pane closes. With `[jobs] close_on_success = false` or
  `--keep` it stays. The pane you ran it from gets the *done* mark (a muted dot), plus a macOS
  notification when Dealer isn't in front; `--quiet` skips both.
- **Failure:** the pane stays open at a prompt with the command in history reach. It's marked
  *waiting* (the accent outline), so ⌘⇧U (Jump to Next Unread) goes straight to it.
- If Dealer can't be reached when the job ends (it was restarted, say), the pane just stays open.

Shells: zsh, bash and other POSIX shells. fish doesn't have `$?`; use
`dealer create --no-focus` + `send-text` with your own tail there.

**Not built in (see #21):** routing to the workspace that "owns" `$PWD`. Workspaces have no root
directory yet; use `-t workspace:N` to pick one explicitly.

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

### Route by cwd: open in the workspace that owns `$PWD`

Workspaces don't have a directory of their own yet, so this treats a workspace as owning the
cwds of its panes. It picks the workspace with the deepest pane cwd containing `$PWD`, and
creates a workspace rooted at `$PWD` if none matches.

```sh
ws=$(dealer list --json | jq -r --arg pwd "$PWD" '
  [.windows[].workspaces[] | {id, cwd: ([.decks[].tabs[].panes[].cwd // empty
     | select(. as $c | ($pwd + "/") | startswith($c + "/"))] | max_by(length))}
   | select(.cwd)] | max_by(.cwd | length) | .id // empty')
if [ -n "$ws" ]; then dealer create tab -t "workspace:$ws" --cwd "$PWD"
else dealer create workspace --cwd "$PWD" --name "$(basename "$PWD")"; fi
```

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
