# MyTerm

macOS terminal: Swift/AppKit shell around **libghostty** (Ghostty's embedding C API, `ghostty.h`),
implementing the "Panes and Decks" layout. The design spec is `~/Downloads/Panes and Decks.html`;
use its vocabulary (pane, deck, promote, fold, move to tab), not "split with/without tabs".

## Building

- `vendor/GhosttyKit.xcframework` is git-ignored and required. Produce it with
  `scripts/build-ghosttykit.sh`, which builds from `~/git/ghostty`.
- Ghostty needs **zig 0.15**. Homebrew's default `zig` is 0.16 and fails; the script uses
  `/opt/homebrew/opt/zig@0.15/bin/zig`.
- The Swift code is written against the `ghostty.h` shipped in the xcframework. If you
  update the ghostty checkout, rebuild the framework and expect C API drift (struct fields, enum names).
- `swift build` compiles the code; `scripts/bundle.sh [debug|release]` produces `build/MyTerm.app`.

## Verifying changes

- Run `swift build && MYTERM_SELFTEST=quit .build/debug/MyTerm`. It replays the design walkthrough
  through the controller and asserts the deck/tab/pane tree after each step; it exits 0 on pass.
  When you add or change a structural behavior, add a step in `Sources/MyTerm/SelfTest.swift`.
- To look at the UI, run with `MYTERM_SELFTEST=1 MYTERM_SELFTEST_DELAY=2`, which keeps the window
  open, and capture it with `screencapture -x -o -l<windowID>`. Get the window ID from
  `CGWindowListCopyWindowInfo`, filtering on owner name "MyTerm" and layer 0.
- **Don't clobber the user's session.** A normal launch restores, and on quit overwrites,
  `~/Library/Application Support/MyTerm/session.json`. Self-test mode neither reads nor writes it.
  If you do a normal launch for testing, back up that file first and restore it afterwards.
- The self-test calls controller methods directly. Real mouse dragging (`DragController`'s
  tracking loop) and divider dragging are not covered; say so when reporting.

## Behavior decisions to preserve

- Menu shortcuts beat ghostty keybinds: `SurfaceView.performKeyEquivalent` asks the main menu
  first. For example, ⌘⇧P is Promote, not Ghostty's command palette.
- Ghostty keybind actions (`new_split`, `goto_tab`, …) are mapped onto our own commands in
  `GhosttyRuntime.handle`, so user configs still work.
- Keyboard/IME handling is a trimmed port of Ghostty's own
  `~/git/ghostty/macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift`. Check that file
  before changing key handling.

See `Sources/MyTerm/CLAUDE.md` for code invariants.
