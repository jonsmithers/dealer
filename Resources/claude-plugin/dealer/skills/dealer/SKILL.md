---
name: dealer
description: Drive Dealer, the macOS terminal this session runs in, with the `dealer` CLI. Use it when the user asks you to open, split, rename, color, focus, resize or close panes, tabs, decks or workspaces; to run something in a pane of its own ("beside you", "in a new tab", "in the background"), such as an editor, dev server, watcher or test run they want to see; to type into another pane or read what it shows; or to find which pane runs something. Not for running a command whose output you need: use your own Bash tool for that.
---

# Driving Dealer

You run in a Dealer pane. `dealer` talks to the running app over its control socket. Every
command replies only after the change is applied, so there's nothing to wait or poll for.
If `dealer` isn't on `PATH` (a development build), run `"$DEALER_CLI"` instead. `dealer help`
prints the full usage; this guide covers what you need.

## Keep it quiet

Arranging panes is a side errand. Whatever the user is actually working on is the point.
- **One Bash call per request.** Chain the action and its check (`&&`, `||`). The recipes below
  resolve targets themselves, so you don't need `identify`, `list` or `read` first.
- **Don't narrate.** Say nothing about which pane you picked or why, and keep the tool
  description short ("Open nvim to the right"). Afterwards, one short clause: "nvim's open in the
  pane to your right." Leave out pane IDs unless the user works with them.
- **Don't deliberate.** The words below have fixed meanings. Ask only when the user names
  something that matches several panes, or before typing into a busy pane or closing one.

## Vocabulary

- **Window** → **workspace** (a window shows one at a time) → **deck** (a region of the window
  with its own tab strip) → **tab** → **pane** (one terminal). Use these words with the user.
- Every object has a numeric ID, stable for its lifetime (it survives moves) but not across
  restarts. Never reuse IDs from an earlier session; look them up again.
- **Targets** (`-t`): `pane:N` (or just `N`), `tab:N`, `deck:N`, `workspace:N`, `window:N`,
  `focused`, or `left`/`right`/`up`/`down`: the pane beside yours that way (as ⌘⌥-arrow picks it,
  also across decks). With no target, a command acts on **your own pane** (`$DEALER_PANE_ID`). A
  pane command given a tab/deck/workspace/window uses the pane that would get focus there.

## Where to act

- "Beside you", "next to you", "in a new split", or no place named: a new pane split from yours
  (`create pane --side right`; your own pane is the default target, so leave out `-t`).
- "The neighboring split", "the other split", "the pane on the right" / "below": the existing pane
  that way, `-t right` (or `left`/`up`/`down`). No side named means `right`. If there's no pane
  there, or it's busy, make a new one on that side instead (recipe below).
- "The focused pane", "the current tab", "what I'm looking at": `-t focused`. It can be a
  different pane from yours (the user may be looking elsewhere while you work).
- A name ("the api workspace", "the tab running vite", "the nvim pane"): find it first. A name
  beats everything else.
  - `dealer find --title RE`, `--process RE` (any process's full command line on the pane's
    tty) or `--cwd DIR` prints matching pane IDs in tree order.
  - `dealer list` shows the whole tree with IDs, titles, cwds and processes; `dealer list --json`
    for workspace names, colors and every field.
  - If several panes match and the user's words don't decide it, ask.

## Commands

```sh
dealer identify                    # your pane and the focused one, with tab/deck/workspace/window IDs
dealer list [--json]               # the whole tree
dealer find --process '(^|/)vite( |$)'

# New pane/tab/deck/workspace beside the target; prints the new pane's ID.
dealer create pane --side right --no-focus                 # split beside you
dealer create pane --side down --size 30% --no-focus       # rows/columns, a percent, or 0.3
dealer create tab --title server --no-focus                # a new tab in your deck
dealer create deck --side right --no-focus                 # a new deck with its own tab strip
dealer create workspace --name api --cwd ~/git/api --no-focus
#   --cwd DIR (default: the target's cwd), --command CMD (runs instead of a shell; the pane
#   closes when it exits), --title T, --json (all the new IDs)

dealer send-text -t 12 --enter 'npm run dev'     # type a line and press Enter
dealer send-text -t right --if-idle --enter nvim # only if that pane sits at its shell prompt
dealer send-text -t 12 --key ctrl+c              # keys: enter tab esc up down f5 ctrl+x alt+x ...
dealer send-text -t 12 --paste --stdin < file    # a bracketed paste
dealer read 12                                   # the pane's screen as text (also nvim and other TUIs)
dealer read 12 --lines 20                        # just the last 20 lines
dealer read 12 --scrollback                      # with its history
dealer read 12 --wait 'Local: +http' --timeout 30   # until a regex matches (exit 1 on timeout)
dealer focus 12                                  # also brings its window, workspace and tab forward
dealer rename -t 12 'api server'                 # a pane; --tab or --workspace for those; '' resets
dealer color --tab green                         # red orange yellow green teal blue purple pink, #rrggbb, none
dealer resize -t 12 --to 30%                     # or --by +5 / --by -10%; --axis width|height
dealer close -t 12                               # closes without asking
dealer run -- make test                          # a background job pane (see below)
```

Errors exit 1 with a message on stderr, usage errors exit 2, and 3 means Dealer isn't
reachable.

## Doing it well

- **Pass `--no-focus`** to `create`, unless the user asked to be taken there. Focus moves the
  user's keyboard, and they may be typing to you.
- **Starting a program in a pane** (nvim, a dev server, `tail -f`, a watcher): `send-text
  --enter` the command into a shell, so it runs with the user's `PATH`, aliases and rc
  environment, and the pane comes back to a prompt when it exits. In a new pane:
  ```sh
  p=$(dealer create pane --side right --no-focus) && dealer send-text -t "$p" --enter 'npm run dev'
  ```
  In the neighboring pane, or a new one on that side when it has none or is busy:
  ```sh
  dealer send-text -t right --if-idle --enter nvim 2>/dev/null ||
    dealer send-text -t "$(dealer create pane --side right --no-focus)" --enter nvim
  ```
  `create --command CMD` is for a pane that should close when the program exits. It runs CMD
  from a login shell, which reads the user's profile but not `.zshrc`, so a program only
  `.zshrc` puts on `PATH` isn't found (`command not found`).
- **Check that it worked** when the program prints something you can recognize (a server's
  `ready` or URL, a test summary). Add `&& dealer read ID --wait RE` to the same call, with RE
  matching text only the output shows, not the command you typed: the typed line is on the
  screen too. An editor or a shell needs no check. On a timeout, look at what `read` printed and
  tell the user what you see.
- **A one-off command the user wants run in a pane** ("run the tests beside you"):
  `dealer run -- CMD...`. It's a job pane split below you, with focus left alone. On success it
  shows `DONE`, lingers a few seconds and closes. On failure it stays open, marked failed, for
  the user to inspect. `--tab` makes it a background tab, `--keep` keeps it open on success. One
  argument is a shell string (`dealer run 'make && make test'`), several are an argv.
- **Reading a pane:** `dealer read` gives what's on its screen. For a command's full output,
  running it with your own Bash tool is still simpler; `read --scrollback` holds only what the
  terminal kept, wrapped to its width.
- **Typing into a pane you didn't create:** text typed at an editor or a REPL goes to that
  program, not a shell. When you mean to reach a shell, `--if-idle` checks that for you: it fails
  without typing anything unless the pane sits at its shell prompt. To type into a program on
  purpose (a key for the user's nvim), `dealer read` it first. Don't type into the user's panes,
  close them, or change their titles or colors unless they asked.
- **Your own pane:** never `send-text` into it, and never `close` it. `dealer identify --caller`
  prints its ID.
- **Panes you made:** keep their IDs for later commands. Tell the user where by position, not
  by ID ("the dev server's running in a new pane to your right"). Close them when you're done
  with them, unless the user wants them kept.
- **Attention is automatic:** Dealer already marks your pane when you wait for permission or
  finish a turn. Don't call `dealer notify` for that.
