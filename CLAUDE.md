# Dealer

macOS terminal: Swift/AppKit shell around **libghostty** (Ghostty's embedding C API, `ghostty.h`),
implementing the "Panes and Decks" layout. The design spec is `~/Downloads/Panes and Decks.html`;
use its vocabulary (pane, deck, promote, fold, move to tab), not "split with/without tabs".
Formerly called MyTerm (the GitHub repo is `jonsmithers/dealer`).

## Building

- `vendor/GhosttyKit.xcframework` is git-ignored and required. Produce it with
  `scripts/build-ghosttykit.sh`, which builds from `~/git/ghostty`. A new git worktree doesn't have
  it; symlink `vendor/GhosttyKit.xcframework` from the main checkout instead of rebuilding.
- Ghostty needs **zig 0.15**. Homebrew's default `zig` is 0.16 and fails; the script uses
  `/opt/homebrew/opt/zig@0.15/bin/zig`.
- The Swift code is written against the `ghostty.h` shipped in the xcframework. If you
  update the ghostty checkout, rebuild the framework and expect C API drift (struct fields, enum names).
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
- **Don't clobber the user's session.** A normal launch restores, and on quit overwrites,
  `~/Library/Application Support/Dealer/session.json`. Self-test mode neither reads nor writes it.
  If you do a normal launch for testing, back up that file first and restore it afterwards.
  Don't "restore" by deleting the Dealer file: if it's missing on load, `SessionSnapshot.migrateLegacy`
  copies in the stale pre-rename `Application Support/MyTerm/session.json`. That legacy file is only
  ever read, never written.
- To test session restore: write a crafted session.json, launch `.build/debug/Dealer`, screenshot,
  then `kill -TERM` it. SIGTERM skips `applicationShouldTerminate`, so the file isn't rewritten.
  Afterwards restore your backup (or remove the Dealer dir if it didn't exist before).
- To screenshot under a different ghostty theme without touching the user's config, point
  `XDG_CONFIG_HOME` at a temp dir containing `ghostty/config` (e.g. `theme = Catppuccin Latte`).
  Ghostty also reads `~/Library/Application Support/com.mitchellh.ghostty/config`, which XDG
  doesn't redirect and which loads after it; check that it has no color settings.
- **Locked screen:** `ghostty_surface_new` returns nil for every pane and `screencapture -l` fails.
  Self-test checks that need a live shell or cell metrics print `(skipped …)` and still pass; if
  you see those, say that shell-level behavior (send-text, `--command`, process listing, `--size`
  in rows) was not verified. To check custom drawing, render the view offscreen from a temporary
  step (`bitmapImageRepForCachingDisplay` + `cacheDisplay`); Metal surfaces come out blank that way.
- To try the CLI against a dev build: run `DEALER_SELFTEST=1 .build/debug/Dealer` (it listens on
  `$TMPDIR/dealer-selftest-<pid>.sock`), then
  `DEALER_SOCKET=$TMPDIR/dealer-selftest-<pid>.sock .build/debug/Dealer list`. Inside a Dealer pane,
  `DEALER_SOCKET`/`DEALER_PANE_ID` are inherited and point at the user's real app, so always
  override `DEALER_SOCKET` when testing. A second normal launch doesn't steal the socket (it falls
  back to `dealer-<pid>.sock`), but it still restores and overwrites session.json.
- The self-test mostly calls controller methods directly. `DragController`'s tracking loop can be
  driven by queuing events with `window.postEvent` before `drag.begin` (see `SelfTestSidebar.swift`),
  but only drops onto the workspace sidebar do that so far. Real mouse movement, hover-to-switch,
  drag highlights and divider dragging are not covered; neither are macOS notifications (bundle
  only), modal dialogs, or real key presses. Say so when reporting.

## Behavior decisions to preserve

- Menu shortcuts beat ghostty keybinds: `SurfaceView.performKeyEquivalent` asks the main menu
  first. For example, ⌘⇧P is Promote, not Ghostty's command palette, and ⌃1–9 switch workspaces,
  so programs never see ctrl-digit.
- Ghostty keybind actions (`new_split`, `goto_tab`, …) are mapped onto our own commands in
  `GhosttyRuntime.handle`, so user configs still work.
- Keyboard/IME handling is a trimmed port of Ghostty's own
  `~/git/ghostty/macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift`. Check that file
  before changing key handling.
- Workspaces are per-window (a window shows one at a time), not global. Closing the last deck of a
  workspace closes the workspace, and the last workspace closes the window; there is no empty
  workspace state. Moves into another workspace don't follow (the view stays put), except for
  "New Workspace" targets and when the move empties the source workspace.
- Chrome colors come from the user's ghostty config (via `Theme`), not a fixed palette, and light
  vs dark follows the terminal background's luminance, not the macOS appearance. Focus is shown
  Ghostty-style by veiling unfocused panes (`unfocused-split-fill`/`-opacity`); pane rings are
  reserved for attention. Don't reintroduce focus borders.
- Coding-agent keys: ⌘⇧U Jump to Next Unread, ⌥⌘A New Agent Pane, ⌥⇧⌘A New Agent Pane in
  Worktree. The agent command comes from `DEALER_AGENT_COMMAND`, then the `agentCommand` user
  default (`dev.smithers.dealer`), then `claude`. It is *typed* into the new pane's shell (not the
  surface `command`), so the pane returns to a prompt when the agent exits.
- `dealer` is the app binary itself: `main.swift` runs it as a socket client (no app launch) when
  argv[0] is `dealer` or argv[1] is a known subcommand. The symlink lives in
  `Contents/Resources/bin`, not `Contents/MacOS`, because `dealer` and `Dealer` collide on
  case-insensitive volumes. `Pane.childEnvironment` replaces the PATH Ghostty builds, so Ghostty's
  own append of `Contents/MacOS` is dropped on purpose.
- Control-socket commands are synchronous: the reply is sent only after main has applied the
  change. New commands go in `ControlHandler`, call the same controller methods the menus use, get
  a step in `SelfTestCLI.swift`, and are documented in `docs/cli.md`.
- `DEALER_*` env vars read through `SelfTest.env` fall back to the pre-rename `MYTERM_*` spelling,
  so code that strips an env var for a child process must strip both (see `SelfTestCLI.swift`).
  New variables such as `DEALER_PANE_ID` don't get the fallback.

See `Sources/Dealer/CLAUDE.md` for code invariants.
