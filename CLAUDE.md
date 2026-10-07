# Dealer

macOS terminal: Swift/AppKit shell around **libghostty** (Ghostty's embedding C API, `ghostty.h`),
implementing the "Panes and Decks" layout. The design spec is `~/Downloads/Panes and Decks.html`;
use its vocabulary (pane, deck, promote, fold, move to tab), not "split with/without tabs".
Formerly called MyTerm (the GitHub repo is `jonsmithers/dealer`).

## Building

- `vendor/GhosttyKit.xcframework` is git-ignored and required. Produce it with
  `scripts/build-ghosttykit.sh`, which finds the Ghostty checkout via `--ghostty`/`$GHOSTTY_SRC`,
  then a sibling `../ghostty` (of the main checkout too, so it works from worktrees), then a prompt.
  A new git worktree doesn't have the framework; symlink `vendor/GhosttyKit.xcframework` from the
  main checkout instead of rebuilding.
- The same run writes `vendor/ghostty-resources/{ghostty,terminfo}` (shell integration, themes,
  terminfo; ~2.5 MB, git-ignored) plus a `ghostty-commit` stamp, from a fresh install prefix (#41).
  `bundle.sh` copies them into `Contents/Resources` (it warns and bundles without them if missing),
  with `Resources/THIRD-PARTY-NOTICES.txt` (Ghostty and iTerm2-Color-Schemes, both MIT).
  `check-ghostty.sh` checks the stamp against the pin. Worktrees don't need a link: the self-test
  also looks in the main checkout's `vendor/`. The script's `rm` of a symlinked framework only removes the
  link, but pass `--out <tmp>` when testing it, and use `--dry-run` to avoid a slow zig build.
- **Ghostty is pinned** in `scripts/ghostty.version`, and the script refuses other commits unless
  you pass `--any-version`. `ghostty.h` is Ghostty's internal API and breaks without notice. For
  example, after the pin the clipboard callbacks and `ghostty_surface_complete_clipboard_request`
  changed signature, and `main` moved to zig 0.16. Never move the user's Ghostty checkout yourself;
  for a different commit, use a `git clone --shared` into a temp dir. To bump the pin, rebuild, fix
  the drift, update the hash in **both** `scripts/ghostty.version` and
  `GhosttyVersion.pinnedCommit`, and run the self-test.
- **The pin is enforced on the vendored framework (#35)**, read from the version string Ghostty's
  build embeds (`ghostty_info()` at runtime, `grep -a` in `scripts/check-ghostty.sh`), not a stamp.
  Three layers: `bundle.sh` runs `check-ghostty.sh` and refuses to bundle a mismatch
  (`GHOSTTY_ANY_VERSION=1` overrides); the self-test fails on a mismatch, so merges do too, and it
  checks that `GhosttyVersion.pinnedCommit` equals `scripts/ghostty.version` (reading the file from the
  source tree via `#filePath`); and at launch the app logs the mismatch and shows a dismissible red
  banner (`GhosttyVersionBannerView`) in all build configs. A library built without git metadata
  records no commit and only gets a warning.
  - To check by hand without touching `vendor/`, run `scripts/check-ghostty.sh <path/to/GhosttyKit.xcframework>`.
    The script only greps the `.a`, so a temp dir holding a small fake `*/libghostty*.a` with a
    `1.3.2-main-+<hash>` string is enough to fake a mismatch.
- **No Xcode needed (#42):** building `vendor/` needs zig 0.15 and the Command Line Tools only; full
  Xcode is needed just to regenerate the shader library when Ghostty's shaders change. How it works,
  pin bumps and removal: `scripts/ghostty-build/README.md`.
- The pinned commit needs **zig 0.15**. The script reads `minimum_zig_version` from the checkout's
  `build.zig.zon` and prefers `/opt/homebrew/opt/zig@<ver>/bin/zig`; Homebrew's default `zig` is 0.16.
- `swift build` compiles the code; `scripts/bundle.sh [debug|release]` produces `build/Dealer.app`.

## Running

- `scripts/bundle.sh && open build/Dealer.app` is the real app. Only the bundle has
  `dealer` on `PATH` in its panes (`Contents/Resources/bin`, appended by `Pane.childEnvironment`)
  and macOS notifications (`UNUserNotificationCenter` needs a bundle identifier).
- `.build/debug/Dealer` runs unbundled: no notifications, no `dealer` on `PATH` (use
  `.build/debug/Dealer <subcommand>` as the CLI instead).
- Any normal launch, bundled or not, restores and overwrites the user's session (see below).
  To poke at the UI safely, run `DEALER_SELFTEST=1 .build/debug/Dealer`.

## Verifying changes

- Run `swift build && DEALER_SELFTEST=quit .build/debug/Dealer`. It replays the design walkthrough
  through the controller and asserts the deck/tab/pane tree after each step; it exits 0 on pass.
  When you add or change a structural behavior, add a step. Feature steps live in their own
  `SelfTest<Feature>.swift` files (see `Sources/Dealer/CLAUDE.md`).
- To look at the UI, run with `DEALER_SELFTEST=1 DEALER_SELFTEST_DELAY=2`, which keeps the window
  open, and capture it with `screencapture -x -o -l<windowID>`. Get the window ID from
  `CGWindowListCopyWindowInfo`, filtering on owner name "Dealer", layer 0, and the PID you launched.
- **Kill only your own Dealer processes, by PID** (start it in the background, keep `$!`,
  `kill $PID`). Never `pkill`/`killall` by name or `-f` pattern: other agents' self-tests and
  merges are live Dealer processes too, and `pkill -f` can kill your own shell.
- **Real Claude Code runs:** never against the user's `~/.claude`. Set `CLAUDE_CONFIG_DIR` to a
  scratch directory; auth still works, and transcripts land there instead of
  `~/.claude/projects`. Pre-set `hasCompletedOnboarding` and the project's
  `hasTrustDialogAccepted` in its `.claude.json` to skip first-run dialogs. Drive interactive
  sessions in a self-test-mode Dealer pane with `dealer create pane --no-focus` +
  `dealer send-text`. `dealer list` has no attention field, so to see hook calls, point
  `DEALER_CLI` at a logging shim. A Dealer launched from inside a Claude Code session (as an agent
  does) scrubs Claude's session-identity variables at startup (`ClaudeHooks.inheritedSessionVariables`),
  so `claude` in its panes behaves like a top-level session.
- **Don't clobber the user's session.** A normal launch restores, and on quit overwrites,
  `~/Library/Application Support/Dealer/session.json`. Self-test mode neither reads nor writes it.
  If you do a normal launch for testing, back up that file first and restore it afterwards.
  Don't "restore" by deleting the Dealer file: if it's missing on load, `SessionSnapshot.migrateLegacy`
  copies in the stale pre-rename `Application Support/MyTerm/session.json`. That legacy file is only
  ever read, never written.
- **Don't touch the user's settings file** (`~/.config/dealer/settings.toml`, or under
  `$XDG_CONFIG_HOME`). Self-test mode already uses a temp config home. For a normal launch against
  a test file, set `XDG_CONFIG_HOME` to a temp dir (ghostty reads its config from there too).
- Dealer's own settings belong in settings.toml via `Settings` (see `Sources/Dealer/CLAUDE.md`),
  never new UserDefaults keys or env-var reads scattered through the code.
- To test session restore: write a crafted session.json, launch `.build/debug/Dealer`, screenshot,
  then `kill -TERM` it. SIGTERM skips `applicationShouldTerminate`, so the file isn't rewritten.
  Afterwards restore your backup (or remove the Dealer dir if it didn't exist before).
- To screenshot under a different ghostty theme without touching the user's config, point
  `XDG_CONFIG_HOME` at a temp dir containing `ghostty/config` (e.g. `theme = Catppuccin Latte`).
  Ghostty also reads `~/Library/Application Support/com.mitchellh.ghostty/config`, which XDG
  doesn't redirect and which loads after it; check that it has no color settings.
- **README demo recordings (#26, #28).** Regenerate after any visual change:
  `swift build && scripts/record-demo.sh <out-dir>` records every demo (or name some: `drag tabs
  workspaces attention`). Prerequisites: an unlocked screen, Screen Recording permission for the
  app running the script, ffmpeg, and hands off the machine while it runs (the demo window floats
  on top). The script writes `<demo>.gif` (5 MB budget, enforced), `<demo>.mp4`, and contact sheets
  in `<out-dir>/review/`. **Read every sheet before publishing** (privacy: only `/tmp/demo` paths,
  a `demo $` prompt, nothing but the Dealer window). Then publish explicitly with
  `scripts/record-demo.sh <out-dir> --publish <worktree of the media branch>`, which commits there
  and prints the `git push origin media` to run. Nothing is pushed implicitly. GIFs/MP4s live only on
  the orphan `media` branch, never on master; the README links
  `https://github.com/jonsmithers/dealer/raw/media/demos/<file>`.
  - How it works: `DEALER_SELFTEST=1 DEALER_DEMO=<name>` runs a script in `Demo.swift`.
    `DemoMouse` posts real mouse events (`window.postEvent`) along eased paths at 60 Hz, so
    DragController's tracking loop, buttons and rows handle them as they would a person's, and
    draws a pointer sprite (system arrow, open hand over pane bars, closed hand while dragging).
    Hover can't come from posted events (tracking areas follow the window server's cursor), so the
    driver sends `mouseEntered`/`mouseExited`/`mouseMoved` to the views under its pointer itself.
  - Targets are found by identity (the pane titled X, its tab button or bar, the sidebar row for
    workspace Y, a fraction of a view's bounds, the deck area's edge), never pixel coordinates, so
    restyles don't break the scripts. Add new beats the same way.
  - The recorder (ffmpeg/avfoundation on the window's screen region, without the real pointer) stops
    when the demo prints `DEMO DONE`, *before* the app exits: a frame after the window closes would
    show the user's screen. `screencapture -v -l` isn't used because it records the real pointer
    and macOS swaps the traffic lights for a capture badge.
  - Demos run with `tabs_in_titlebar = true` (one switch, `Demo.tabsInTitlebar`, written to the
    demo's temp settings). Grab tabs with the `grip(…)` helper (lower half = tab drag; the upper
    half drags the window, #27). Captions sit in a band under the decks (`Demo.captionBand`, 0
    outside demos, subtracted in `deckArea`). Each caption logs `DEMO BEAT <tree>`, so a run
    can be checked from its log without recording.
  - Demo shells use `ZDOTDIR=/tmp/demo` (set up by the script) and source Ghostty's shell integration;
    without it every pane counts as busy and closing one asks for confirmation.
- **The self-test never shows modals (#38).** Close and quit confirmations go through
  `Confirmation.skip` (one switch, on in self-test and demo mode), which accepts and logs
  `(auto-accepted confirmation: …)`. After every step the runner fails the step that left a sheet or
  app-modal window open, naming it, then cancels it. New confirmations must use
  `TerminalWindowController.confirm` or `Confirmation.skip`, never a bare `NSAlert`.
- **Display asleep:** with the screen locked *and* the display asleep (no active displays,
  `displaysleep` is 10 min here), click/drag/menu-key steps fail: sometimes only ⌘B (88), sometimes a
  block of ~21 (sidebar, switcher, titlebar tabs, edge split) followed by a crash. This explains
  the "intermittent failure block". The runner prints `SELFTEST NOTE: display asleep, screen locked` at start and
  `(environment: …)` on each failure; treat such a run as not verified and rerun on an awake screen.
- **Locked screen:** `ghostty_surface_new` returns nil for every pane and `screencapture -l` fails.
  Self-test checks that need a live shell or cell metrics print `(skipped …)` and still pass; if
  you see those, say that shell-level behavior (send-text, `--command`, process listing, `--size`
  in rows) was not verified. To check custom drawing, read pixels only through
  `PixelProbe.sample` (SelfTestPixels.swift), which renders offscreen and works while locked;
  Metal surfaces come out blank that way.
- **Shell integration in the self-test (#39, #41):** test shells use `vendor/ghostty-resources`
  from the pinned build (see `GhosttyResources` in `Sources/Dealer/CLAUDE.md`), not whatever
  Ghostty.app is installed, and not the `GHOSTTY_RESOURCES_DIR` your own pane exports. Without the
  vendored directory the run logs that and falls back to an installed Ghostty.app. To force a
  directory set `DEALER_GHOSTTY_RESOURCES_DIR=<dir>`; set it empty to run without integration.
  The self-test still loads your real ghostty config (only Dealer's settings use a temp home), so
  a ghostty config problem, such as a theme that can't be resolved, can show up in banner steps.
- To try the CLI against a dev build: run `DEALER_SELFTEST=1 .build/debug/Dealer` (it listens on
  `$TMPDIR/dealer-selftest-<pid>.sock`), then
  `DEALER_SOCKET=$TMPDIR/dealer-selftest-<pid>.sock .build/debug/Dealer list`. Inside a Dealer pane,
  `DEALER_SOCKET`/`DEALER_PANE_ID` are inherited and point at the user's real app, so always
  override `DEALER_SOCKET` when testing. A second normal launch doesn't steal the socket (it falls
  back to `dealer-<pid>.sock`), but it still restores and overwrites session.json.
- The self-test mostly calls controller methods directly. `DragController`'s tracking loop can be
  driven by queuing events with `window.postEvent` before `drag.begin` (see `SelfTestSidebar.swift`),
  drops onto the workspace sidebar, pane centres (`SelfTestDragSettle.swift`) and the window edges
  (`SelfTestEdgeSplit.swift`, which also has a drag-to-a-window-point helper) do that. Real mouse movement, hover-to-switch,
  drag highlights and divider dragging are not covered; neither are macOS notifications (bundle
  only), what a confirmation dialog looks like (self-test mode auto-accepts them), or real key presses. Say so when reporting.

- **Memory (#43):** `DEALER_SELFTEST_ONLY=<title prefix>` runs only matching steps (e.g. `memory:`,
  whose steps need no earlier state). `DEALER_SELFTEST_LIVE=1` prints `LiveObjects` counts after each
  step, next to the panes the windows hold. A full run ends near 6 GB on purpose: the runner's
  name table keeps every named pane (about 120) alive, at about 50 MB each. Measure leaks only on
  your own self-test instance (`footprint -p`, `vmmap --summary`, `heap`, and
  `leaks --traceTree=<addr>`, which is noisy because it scans conservatively). Never attach them
  to the user's Dealer. `dealer diagnose` writes the user-facing report (docs/diagnostics.md).

- **Worktree hygiene:** to squash a branch, use `git reset --soft $(git merge-base HEAD master)`,
  never `git reset --soft master` (master moves under you, and the squash silently reverts other
  branches' work). `scripts/bundle.sh` registers each bundle with Launch Services (#30), so before
  deleting a worktree that you bundled in, run `lsregister -u <worktree>/build/Dealer.app`. Otherwise
  stale records for `dev.smithers.dealer` pile up and can confuse Notification Center's icon.

## Behavior decisions to preserve

- Menu shortcuts beat ghostty keybinds: `SurfaceView.performKeyEquivalent` asks the main menu
  first. For example, ⌘⇧P is Promote, not Ghostty's command palette, and ⌃1–9 switch workspaces,
  so programs never see ctrl-digit.
- Ghostty keybind actions (`new_split`, `goto_tab`, …) are mapped onto our own commands in
  `GhosttyRuntime.handle`, so user configs still work.
- Keyboard/IME handling is a trimmed port of Ghostty's own
  `macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift` in ghostty-org/ghostty (read it at the
  pinned commit, `git show <pin>:<path>`, since upstream moves on). Check that file
  before changing key handling.
- `[window] tabs_in_titlebar` (#16, off by default) moves only top-edge decks' strips into the
  titlebar row; lower decks keep theirs. In top-bar workspace mode the pills keep a fixed left
  segment and strips start after it (not disabled). A strip that would be clipped below
  `titlebarStripMinWidth` stays in its deck.
- Workspaces are per-window (a window shows one at a time), not global. Closing the last deck of a
  workspace closes the workspace, and the last workspace closes the window; there is no empty
  workspace state. Moves into another workspace don't follow (the view stays put), except for
  "New Workspace" targets and when the move empties the source workspace.
- Chrome colors come from the user's ghostty config (via `Theme`), not a fixed palette, and light
  vs dark follows the terminal background's luminance, not the macOS appearance. Focus is shown
  Ghostty-style by veiling unfocused panes (`unfocused-split-fill`/`-opacity`); pane rings are
  reserved for attention. Don't reintroduce focus borders.
- Workspace and tab colors (#9) are a chip/underline plus a faint tint, never an outline (outlines
  mean attention). **A workspace's color shows only on its switcher entry**: the sidebar row, or
  the pill in top-bar mode (#15, #18; the user's call). Not in the deck area, and it has no effect
  at all on tabs (tint, underline, fill, or deck-color fallback). Tabs get color only from their own `Tab.color`; the
  per-deck underline stays and a tab color overrides it on that tab. `[colors] auto_assign`
  defaults to off.
- Attention clears in the model at once, but its ring/outline/dot fade out (~0.8 s, plus a 0.5 s hold
  after ⌘⇧U or a notification click) so you see which pane called you (#34). Only those layers
  and drawings animate, never terminal surfaces. Reduce Motion skips the fade.
- Coding-agent keys: ⌘⇧U Jump to Next Unread, ⌥⌘A New Agent Pane, ⌥⇧⌘A New Agent Pane in
  Worktree. The agent command comes from `DEALER_AGENT_COMMAND`, then `[agent] command` in
  settings.toml, then the legacy `agentCommand` user default, then `claude`. It is *typed* into the new pane's shell (not the
  surface `command`), so the pane returns to a prompt when the agent exits.
- `dealer` is the app binary itself: `main.swift` runs it as a socket client (no app launch) when
  argv[0] is `dealer` or argv[1] is a known subcommand. The symlink lives in
  `Contents/Resources/bin`, not `Contents/MacOS`, because `dealer` and `Dealer` collide on
  case-insensitive volumes. `Pane.childEnvironment` replaces the PATH Ghostty builds, so Ghostty's
  own append of `Contents/MacOS` is dropped on purpose.
- Control-socket commands are synchronous: the reply is sent only after main has applied the
  change. New commands go in `ControlHandler`, call the same controller methods the menus use, get
  a step in `SelfTestCLI.swift`, and are documented in `docs/cli.md`.
- `dealer run` (#21, `ControlJobs.swift`) types the command into a normal interactive shell with
  the tail `; "$DEALER_CLI" job-done $? && exit`, and keeps the outcome policy (close on success,
  stay and mark waiting on failure) in Dealer, not in user shell functions. Don't switch it to the
  surface `command` (aliases and the failed-job prompt would be lost), and don't detect the end
  with ghostty's COMMAND_FINISHED (it fires for every command and needs shell integration).
  - On success Dealer also removes the pane itself: ghostty on macOS keeps a shell that exits
    within `abnormal-command-exit-runtime` (250 ms) open as "abnormal", so a quick job's `exit`
    alone never closes it. Any pane-closing feature that relies on a fast shell exit has the same trap.
  - Quoting (user's call): ONE CLI argument is a raw shell string; SEVERAL are an argv, quoted
    word by word. The documented one-liner is `b() { dealer run -- "$@"; }`, never `"$*"`.
  - Routing is by panes' current cwds (deepest containing `$PWD`, caller's workspace on ties,
    else a new workspace named after the directory). The user rejected workspace root
    directories in the model; don't add them for this.
- New panes inherit the source pane's cwd (#32) through `WorkingDirectory.inherited(from:for:)`,
  which honors ghostty's `split-`/`tab-`/`window-inherit-working-directory` (workspaces map to
  `window`). Any new creation path should go through it; `dealer create` deliberately uses its
  target's cwd instead, and session restore its saved cwd.
- `DEALER_*` env vars read through `SelfTest.env` fall back to the pre-rename `MYTERM_*` spelling,
  so code that strips an env var for a child process must strip both (see `SelfTestCLI.swift`).
  New variables such as `DEALER_PANE_ID` don't get the fallback.

See `Sources/Dealer/CLAUDE.md` for code invariants.
