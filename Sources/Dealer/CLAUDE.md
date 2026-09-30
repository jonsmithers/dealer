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

## Self-test sections

- Feature steps live in their own files (e.g. `SelfTestWorkspaces.swift`) and are added through
  the `SelfTestKit` passed from `runSelfTest`, one call line per section.
