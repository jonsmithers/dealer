# Code invariants

## Model (`Model.swift`)

- One generic binary tree, `Node<Leaf>`, serves both levels: `Node<Pane>` inside a `Tab`, and
  `Node<Deck>` for the window.
- **Nodes are reference types on purpose.** Fold origins (`FoldOrigin`), the "select parent"
  selection, and dividers all hold on to specific `Node` objects.
  - Mutate trees only through `Node.insert` / `Node.remove`, which re-parent the existing nodes.
  - Rebuilding or copying a tree silently breaks fold-back-to-origin.
- `Node.remove` returns the new root, or `nil` when the tree becomes empty. Callers must store it.

## Controller (`TerminalWindowController.swift`)

- Every structural operation ends with `finishChange(focus:)`, which clears the selection and
  any stale zoom, lays out, and restores focus.
- `detach(node:from:in:)`, `detach(tab:from:)` and `detach(deck:)` cascade: an empty tab removes
  itself from its deck, and an empty deck is removed from the window tree. `finishChange` closes
  the window when the root becomes `nil`.
- Moves detach first, then insert. Re-`locate` the target after detaching, because the source's
  cleanup can reshape the tree the target lives in.
- A window holds `workspaces` (never empty while open) and one `activeWorkspace`. Each
  `Workspace` (`Workspace.swift`) owns a deck tree `root`, `focusedPane` and `selection`; the
  controller's `root`/`focusedPane`/`selection`/`decks` are read-only views of the active one.
  - Only the controller assigns `Workspace.root`, `focusedPane` and `selection`, and only it
    changes `workspaces`/`activeWorkspace` (they are `private(set)`; `restore` lives in this file).
  - `Workspace.focusedPane` can be stale after a move; read `validFocusedPane`.
  - `locate`, `deck(of:)` and `detach` search **every** workspace. `decks` is the active
    workspace only; use `allDecks` for anything that must cover hidden workspaces (chrome
    refresh, busy checks, parking views).
  - `finishChange` closes any workspace whose `root` became `nil`, activating a neighbour; the
    window closes with its last workspace. Never leave an empty workspace behind otherwise.
  - `focus(pane)` switches to the pane's workspace. Inactive workspaces' deck views are parked
    hidden (`isHidden` + `setVisible(false)`) by `layoutWindow`, like zoom-hidden decks.

## Layout and views

- Layout is recomputed from the model on every pass: `WindowContentView.layout()` →
  `layoutWindow()` → `layout(deck:)`. Views are cached on the model (`Deck.view` is lazy,
  `Pane.view`, `Pane.surface`), so a pass only sets frames and visibility.
- **Hide surfaces; don't remove them.** Panes in background tabs, and decks hidden by a
  window-level zoom, get `isHidden = true` plus `surface.setVisible(false)`
  (ghostty occlusion). Reparenting a pane between decks is just `addSubview`.
- Divider views are pooled (`syncDividers`), so the divider being dragged survives the relayout
  that its own drag triggers. Don't recreate them per pass.
- All custom views are flipped (top-left origin). `SurfaceView` is flipped too, so mouse and
  IME coordinates go to ghostty unconverted.
- Overlays (drop highlight, selection, drag ghost) must stay above the Metal layers. Call
  `contentView.raiseOverlays()` after adding subviews.

## libghostty lifetime and threading

- A `SurfaceView` owns its `ghostty_surface_t` and frees it in `deinit`.
  - Keep a `Pane` strongly referenced only from its tree node.
  - Every closure capturing a pane or the controller must capture it `weak`, or the shell
    process leaks.
- The `wakeup_cb` and clipboard callbacks can arrive off the main thread. `wakeup` hops to main
  and calls `ghostty_app_tick`. `close_surface_cb` dispatches the close asynchronously to main;
  never free a surface synchronously inside a ghostty callback.
- `ghostty_init` and `ghostty_app_new` run once, in `GhosttyRuntime.start()`. That function
  also sets `GHOSTTY_RESOURCES_DIR` from `/Applications/Ghostty.app` so shell integration and
  terminfo work.

## Workspaces (`Workspace.swift`, `WorkspaceBar.swift`)

- Moves into another workspace follow the usual order: detach, then `place(tab:in:)` /
  `place(deck:in:)`, then `finishChange`. A move to a new workspace inserts an empty
  `Workspace` first; it must be filled before `finishChange`, which would close it.
- Moving a deck to another workspace clears its fold `origin`; fold never crosses workspaces.
- The switcher (`WorkspaceBarView`) sits in the titlebar row of `contentView`, laid out by
  `layoutWorkspaceBar()` from `layoutWindow` and reloaded from `refreshChrome()`. Clicks reach it
  through the transparent titlebar (the self-test clicks a pill via `window.sendEvent`).

- `session.json` stores `workspaces` + `activeWorkspace` per window. The optional `root` field
  exists only to read pre-workspace files (`WindowSnapshot.allWorkspaces` migrates them); keep it
  decodable. Always read `allWorkspaces`, never `workspaces` directly.
- `layoutWorkspaceBar()` must call `bar.layoutSubtreeIfNeeded()` after `reload()`. `reload()` runs
  inside the window's layout pass, so its `needsLayout` is dropped and the pills keep zero frames.
  The bar then draws nothing, but the self-test still passes.
- `WorkspaceBarView.button(at:)` is a test hook: the self-test clicks a pill through
  `window.sendEvent`. That click is the only check that titlebar clicks reach the bar, so keep the
  hook through restyles.
- Workspaces restored but never shown have deck views that aren't in the window yet (their shells
  run anyway, because surfaces are created in `SurfaceView.init`). Ghostty keybind actions from
  those panes find no window controller until the workspace is first shown.

## Self-test sections

- Feature steps live in their own files (e.g. `SelfTestWorkspaces.swift`) and are added through
  the `SelfTestKit` passed from `runSelfTest`, one call line per section.

## Styling (`Theme.swift`)

- `Theme` is the single source for chrome colors, metrics, fonts and animation timings. Don't
  hard-code colors or sizes in views. `Palette` is only a set of legacy forwards to `Theme`.
- The theme is read **once**, in `GhosttyRuntime.start()` via `Theme.load`, before any window
  exists. Config reloads and conditional `theme = light:…,dark:…` are not followed live. Several
  views copy `Theme` colors into `layer.backgroundColor` at init, so supporting a live change means
  re-applying those too, not just redrawing.
- Pane gaps are 1pt (`Theme.Metrics.paneGap`); the visible line is the deck card's background
  (`Theme.divider`) showing through. `DividerView.hitFrame` widens the grab area past the gap onto
  the neighbouring panes, so `syncDividers` keeps dividers above every Pane/Deck view. Adding a pane
  view after the dividers without that re-raise makes the divider ungrabbable.
- The unfocused-pane veil is a subview kept on top of the surface in `PaneView.layout`.
  `dimsWhenUnfocused` is set by the controller in `layout(deck:)` (on when more than one pane is on
  screen). The attention ring is a separate sublayer at zPosition 20, above the veil.
- Height math that includes deck chrome (promote keeping a pane's size) uses
  `DeckView.chromeSize`. Update it if the strip/card insets change.

## Attention and agent status (`Attention.swift`, `AgentStatus.swift`, `AgentLaunch.swift`)

- `setAttention(_:on:raiseOnly:title:body:)` is the only writer of `Pane.attention` besides
  `didFocus`, which clears it (so does `windowDidBecomeKey`, in Attention.swift). It refreshes
  chrome and posts the macOS notification; don't assign `pane.attention` elsewhere.
- Automatic sources (bell, OSC 9/99/777, long `COMMAND_FINISHED`) pass `raiseOnly: true` so they
  never downgrade `waiting`; explicit `dealer notify` sets the state exactly (including `none`).
  A non-`none` state is dropped when the user is already looking at the pane (focused pane, key
  window, active app).
- Tab/deck/workspace attention is computed (max over children), never stored; badges pick it up
  from `refreshChrome()`. The ring is a sublayer named `dealer.attentionRing`, and the self-test
  finds it by that name.
- "running" is `Pane.isReportingProgress` (OSC 9;4 from `GHOSTTY_ACTION_PROGRESS_REPORT`), not a
  process check; attention outranks it in `agentState`. `GitInfo.lookup` is main-thread only and
  caches for 3s; it reads `.git/HEAD` (following a worktree's `gitdir:` file) with no subprocess.
- `SurfaceView.typeText` writes raw pty bytes through ghostty's `text:` binding action (Zig string
  escapes, `\r` = Enter). `ghostty_surface_text` is a *paste* (bracketed), so a newline in it
  won't run a command.

## Control socket (`ControlServer.swift`, `ControlHandler.swift`)

- `ControlHandler.handle` is a plain request → response function; the self-test drives it
  directly and only spawns the binary once for a real socket round-trip.
- Socket IO runs on background threads; `ControlServer.onMain` hops to main with a
  `CFRunLoopPerformBlock` in **default mode**, not `DispatchQueue.main.sync`. That lets requests run
  inside the self-test's nested default-mode waits, and keeps them out of drag tracking loops
  (event-tracking mode) so a script can't restructure the tree mid-drag. Don't switch it to common
  modes or the main queue.
