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

## Tabs in the titlebar (`TitlebarTabs.swift`, #16)

- `placeTabStrips(frames)` runs in `layoutWindow` before the decks lay out, every pass. It
  reparents a top-edge deck's `strip` into the content view's titlebar row and sets
  `DeckView.stripInTitlebar` (the card then fills the deck). Every other deck gets its strip back,
  and strips in the content view whose deck isn't placed this pass are removed. That covers decks
  that were folded, closed or moved to another workspace: `detach(deck:)` removes the deck view,
  not a strip living outside it. Only strip views move; never recreate decks or surfaces for this.
- The clear line (`titlebarClearX`) is the zoom button, the sidebar toggle, or in top-bar mode the
  pill segment (`WorkspaceBarView.contentWidth`); the bar shrinks to its pills in this mode so it
  doesn't cover strips. New titlebar chrome must push `titlebarClearX` right.
- Titlebar clicks are decided by the window server *before* the app sees them: wherever the view
  under the pointer answers `mouseDownCanMoveWindow == true` (NSView's default for non-opaque views),
  a press drags the window and never reaches the view. Every interactive view that can sit in the
  titlebar row (tabs, buttons, pills, rows) must return `false`; `TabButton` didn't (#27). An
  in-process `window.sendEvent` can't reproduce this, so the self-test asserts the property.
- Empty strip space in the titlebar drags the window (`performDrag`) and runs the system
  double-click action (`AppleActionOnDoubleClick` from the global domain: a macOS setting, not a
  Dealer one). DragController checks titlebar strips before the top-edge promote band they sit in.
- Tests: the strip's frame must equal its deck's x-range clipped at the clear line. For the
  empty-space hit test, pick a point after the strip's last control; with several tabs a strip can
  be full.

## Workspaces (`Workspace.swift`, `WorkspaceSidebar.swift`, `WorkspaceBar.swift`, `WorkspaceSwitcher.swift`)

- Moves into another workspace follow the usual order: detach, then `place(tab:in:)` /
  `place(deck:in:)`, then `finishChange`. A move to a new workspace inserts an empty
  `Workspace` first; it must be filled before `finishChange`, which would close it.
- Moving a deck to another workspace clears its fold `origin`; fold never crosses workspaces.
- The switcher is `WorkspaceSidebarView`, a left column of `contentView` below the titlebar row;
  its toggle (`SidebarToggleButton`) sits in the titlebar row right of the traffic lights. Both are
  placed by `layoutWorkspaceSidebar()` from `layoutWindow`; rows reload from `refreshChrome()`.
- The sidebar never overlays decks: `deckArea` subtracts its column when `isSidebarVisible`, so
  anything sizing against `deckArea` (promote fractions, drop bands, CLI `--size`) already accounts
  for it. `isSidebarVisible` is `sidebarPreference ?? (workspaces.count > 1)`: `nil` is automatic,
  and only the user's toggle sets it. Because the automatic state flips with the workspace count,
  `refreshChrome()` marks the content view for layout when the sidebar's shown state is stale.
- `WindowSnapshot.sidebar` is optional (absent = automatic); keep it that way so older files
  decode. Don't persist the automatic value as an explicit one.
- DragController checks the sidebar before the left-edge promote band (the sidebar lies left of
  `deckArea`); dropping on the source's own workspace is no target.
- There are two switchers, chosen by `Settings.workspaceSwitcher` (#8): the sidebar (default) or
  `WorkspaceBarView` pills in the titlebar row. `isSidebarVisible` is false in top mode *without*
  touching `sidebarPreference`, so switching back restores each window's choice. Never clear or
  rewrite `sidebarPreference` on a mode change. `layoutWorkspaceBar()` runs from
  `layoutWorkspaceSidebar()`; the toggle is hidden and ⌘B disabled in top mode.
- Both switchers conform to `WorkspaceDropTargets`; DragController asks
  `visibleWorkspaceSwitchers`, before the edge bands (the pills lie in the titlebar row, which is
  otherwise the top-edge promote band). A new switcher style only needs to conform.
- Both draw attention only through `AttentionStyle.draw` (#7 owns the look), called last in `draw`.

## Settings (`Settings.swift`, `SettingsFile.swift`, `TOML.swift`, `SettingsBanner.swift`)

- Every Dealer setting is read through a `Settings` accessor; nothing else reads settings.toml or
  the legacy UserDefaults keys. To add a setting: a `schema` entry (dotted key and `Kind`), an
  accessor, a commented line in `SettingsFile.exampleText`, and regenerate
  `docs/settings.example.toml` from it (the self-test checks they're identical). #9's `[colors]`
  goes in the same way. Unknown keys are reported, so add the schema entry before documenting a key.
- Precedence is env var (only where an accessor checks one) > file > legacy UserDefaults
  (`legacyKeys`, read as a fallback when the file doesn't set the key, never written or deleted)
  > default. A bad value is dropped as if unset and reported; `reload` never throws.
- `TOML.swift` is a deliberate in-repo subset parser (no SwiftPM dependency, builds offline). It
  reports unsupported syntax (multi-line strings, inline tables, `[[…]]`, dates) as problems.
  Extend it there if a setting needs more.
- Write-back (`Settings.write`) edits text via `SettingsFile.rewrite`: only the owned key's value
  changes, so comments, spacing and other keys survive. Limit: the existing value must fit on one
  line. Never re-serialize the whole document.
- The watcher's dispatch sources run on a private queue and hop to the main **run loop in default
  mode** (`CFRunLoopPerformBlock`, like `ControlServer.onMain`), with a run-loop timer for the
  debounce. Main-queue delivery would never run during the self-test's nested run-loop waits.
  It re-arms after every event and every reload (atomic saves replace the inode), and watches
  the nearest existing ancestor while `dealer/` doesn't exist.
- Reloads that change effective values or problems post `Settings.didChange` (userInfo `keys`);
  windows observe it (`observeSettings()` in `init`) and re-lay out live without touching surfaces.
  Settings read at pane spawn (`agentCommand`, `agentInjectHooks`) need no observer.
- Self-test mode points `Settings` at a fresh temp config home and blanks the environment and
  legacy lookup (`Settings.start()`), so tests never touch `~/.config/dealer` or the user's defaults.

- `session.json` stores `workspaces` + `activeWorkspace` per window. The optional `root` field
  exists only to read pre-workspace files (`WindowSnapshot.allWorkspaces` migrates them); keep it
  decodable. Always read `allWorkspaces`, never `workspaces` directly.
- `layoutWorkspaceSidebar()` must call `layoutSubtreeIfNeeded()` after `reload()`. `reload()` runs
  inside the window's layout pass, so its `needsLayout` is dropped and the rows keep zero frames.
  The sidebar then draws nothing, but the self-test still passes.
- Test hooks: `WorkspaceSidebarView.row(at:)` / `addRow` and `WorkspaceBarView.button(at:)` /
  `addButton`. `clickForTest`/`dragForTest` refuse hidden views: a click on a hidden target lands on
  whatever is below (a pane bar starts DragController's modal loop and the self-test hangs). The self-test clicks and drags rows
  through `window.sendEvent` (row reorder is plain mouseDown/Dragged/Up on `WorkspaceRow`, which the
  window routes to the pressed view), and runs DragController's real tracking loop by
  `window.postEvent`-queuing the drag and release before calling `drag.begin` (`SelfTestSidebar.swift`).
  Keep these working through restyles.
- Don't name an action after a selector AppKit already answers higher in the responder chain.
  NSWindow implements `toggleSidebar(_:)`, and it sits ahead of the window controller, so a
  nil-target menu item with that action never reached us (#13); hence `toggleWorkspaceSidebar(_:)`.
  Check with `NSWindow.instancesRespond(to:)` when adding a menu action.
- Self-test runs usually aren't the active app, so there is no key window and AppKit routes a
  nil-target menu action nowhere. `pressCmdB` in `SelfTestSwitcher.swift` uses `NSApp.sendEvent` when
  the run is active; otherwise it sends the key through the window and SurfaceView to the menu, then
  resolves the action from SurfaceView up the responder chain as AppKit does. It never re-targets the item.
- Workspaces restored but never shown have deck views that aren't in the window yet (their shells
  run anyway, because surfaces are created in `SurfaceView.init`). Ghostty keybind actions from
  those panes find no window controller until the workspace is first shown.

## Colors (`Colors.swift`)

- `Workspace.color` is read only by the switcher entries (sidebar `WorkspaceRow`, top-bar
  `WorkspaceButton`), the context menus, the session and the CLI (#15, #18). Don't read it in tab,
  deck or window drawing. The self-test renders the deck-area band, every tab strip and every tab button with
  and without a workspace color and requires identical bytes (`PixelProbe.pixels`); the sidebar row
  is the control that must differ. Don't byte-compare views that contain terminals: the Metal
  layers can change between captures (it made this check flaky).

- `Workspace.color` / `Tab.color` are NSColors persisted as "#rrggbb" (`WorkspaceSnapshot.color`,
  `TabSnapshot.color`, both optional). A tab's color lives on the `Tab` object, so it follows any
  move that keeps the object: reordering or moving it to another strip, promoting a whole tab and
  folding it back, moving it to another workspace. Operations that wrap panes in a *new* `Tab`
  (`moveToNewTab`, promoting a pane) start uncolored, and dropping a tab onto a pane
  (`merge(tab:)`) or a fold that splits it into another tab dissolves it and its color.
- Draw colors only through `ColorStyle.drawTint` (inset by `AttentionStyle.outlineWidth`, so the
  attention outline stays outside it) and `drawChip`, and call `AttentionStyle.draw` after them. The
  self-test checks that a waiting-blue workspace or tab doesn't read as outlined.
- Swatches come from `Theme.swatches` (light/dark variants, or `[colors] palette`). Parse
  user-given colors with `Theme.parseColor` (CLI and settings share it).
- `autoAssignColor` runs from `insert(workspace:)`, so it covers every workspace created after the
  window's first: menus, CLI, and moves into a new workspace.

## Self-test sections

- Feature steps live in their own files (e.g. `SelfTestWorkspaces.swift`) and are added through
  the `SelfTestKit` passed from `runSelfTest`, one call line per section.
- **Pixel checks go through `PixelProbe` only** (SelfTestPixels.swift): `sample(_:at:)`, `pixels` (raw bytes for "renders identically"),
  `distance`, `matches`, `isWaitingOutlined`. Never call `cacheDisplay`/`colorAt` in a check
  directly. Two traps it handles:
  - `bitmapImageRepForCachingDisplay` gives a display-space bitmap for a window-backed view and a
    Generic RGB one for a detached view. The latter clips saturated sRGB colors (`#aa00ff` reads
    0.22 off). `sample` renders into its own sRGB bitmap instead.
  - `colorAt` can label display-space components "calibrated RGB"; converting them as labeled
    is off by up to ~0.25. `sample` re-tags mislabeled components with the bitmap's color space.
- Compare with `PixelProbe.matches` (tolerance 2/255) against the exact expected color, e.g.
  `Theme.attentionWaiting`. Reads are exact for solid fills. Don't loosen the tolerance to make a
  check pass; that hid the bug above. The `pixels:` steps fail first if the probe regresses.
  `Theme.withBackground(_:_:)` checks light/dark variants of draw-time colors on a detached view.

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
- What the C API can read (#23): plain colors (`background`, `foreground`, `unfocused-split-fill`,
  `split-divider-color`) and `palette` (`ghostty_config_palette_s`, 256 entries; `Theme.ansi` keeps
  0–15). `TerminalColor` keys (`cursor-color`, `cursor-text`, `selection-background`/`-foreground`)
  have no C conversion, so `ghostty_config_get` returns false for them even when a theme sets them.
  Dealer never calls `ghostty_app_set_color_scheme`, so a conditional `theme = light:…,dark:…`
  always resolves to its light side.
- The pane bar's × (#24) is a `PaneCloseButton` subview, so its click never reaches the bar's
  `mouseDown` (which starts a drag). It closes on mouse-up through `close(pane:)`. Hover state lives
  on the bar (`setHoveringForTest` in the self-test); the status line ends at `statusTrailing`.
- After a drop, the drop preview settles (#28): `DragController.begin` keeps the highlight through
  `perform` and calls `HighlightView.settle(to:)` with the moved content's new frame, which glides
  and fades the overlay only. Terminals are laid out once; never animate pane or surface frames.
  `HighlightView` bumps a generation on every show/hide so a late settle completion can't hide a
  newer preview. Self-test: `SelfTestDragSettle.swift`.
- Height math that includes deck chrome (promote keeping a pane's size) uses
  `DeckView.chromeSize`. Update it if the strip/card insets change.
- New-deck sizing has two rules (#31). Menu Promote of a pane or group split out of a tab keeps
  its size. A whole tab (menu or drag) and every window-edge drop (`promote(evenly:)`) take an
  even share with the decks along that axis (`evenEdgeFraction`, counted after the source deck is
  detached), and the drag preview uses the same function. "Keep its size" for a tab meant the
  whole deck, clamped to 60/40. Self-test: `SelfTestEdgeSplit.swift`.

## Attention and agent status (`Attention.swift`, `AgentStatus.swift`, `AgentLaunch.swift`)

- `setAttention(_:on:raiseOnly:title:body:)` is the only writer of `Pane.attention` besides
  `didFocus`, which clears it (so does `windowDidBecomeKey`, in Attention.swift). `didFocus` clears
  only on a real focus change or when the user is looking (`isLookingAt`): `finishChange` re-focuses
  the already-focused pane after any background change (e.g. a `dealer run` job pane closing), and
  that must not wipe the mark the job just set. It refreshes
  chrome and posts the macOS notification; don't assign `pane.attention` elsewhere.
- Automatic sources (bell, OSC 9/99/777, long `COMMAND_FINISHED`) pass `raiseOnly: true` so they
  never downgrade `waiting`; explicit `dealer notify` sets the state exactly (including `none`).
  A non-`none` state is dropped when the user is already looking at the pane (focused pane, key
  window, active app).
- Tab/deck/workspace attention is computed (max over children), never stored; badges pick it up
  from `refreshChrome()`. The ring is a sublayer named `dealer.attentionRing`, and the self-test
  finds it by that name.
- `failed` (#29) is the top state: failed > waiting > done > unread, for roll-up and ⌘⇧U. It's
  drawn like waiting in `Theme.attentionFailed` (red, light/dark), and its dot carries a `!`
  (`AttentionStyle.drawBang`). `PixelProbe.isFailedOutlined` checks it. Sources: `dealer run`
  failures (ControlJobs), `dealer notify --state failed`, the plugin's StopFailure hook (unless
  `[agent] errors_as_failed = false`, exported as `DEALER_CLAUDE_ERROR_STATE`), and COMMAND_FINISHED
  with a non-zero exit (`commandFinishedAttention`, `[attention] failed_commands`).
- Shell-driven events (ghostty actions, socket requests from a shell) reach `setAttention` through
  `DispatchQueue.main.async`, which the self-test's nested run-loop waits don't drain. Check their
  effect in a *later* step, not by spinning inside the same step.
- Look (#7): `waiting` and `failed` are outlined (`Attention.outlined`). That means the pane ring plus an outline on the tab and
  workspace entry, in `Theme.attentionWaiting` (adaptive blue). `done`/`unread` are a muted dot
  only (`Theme.attentionDone` = `textMuted`). Chrome elements draw attention only through
  `AttentionStyle.draw(_:in:cornerRadius:dotRect:)`, called last in `draw(_:)` so the outline
  sits on the element's outer edge. The self-test samples the top edge's centre pixel
  (`PixelProbe.isWaitingOutlined`), so don't inset the outline or draw it in a sublayer.
- "running" is `Pane.isReportingProgress` (OSC 9;4 from `GHOSTTY_ACTION_PROGRESS_REPORT`), not a
  process check; attention outranks it in `agentState`. `GitInfo.lookup` is main-thread only and
  caches for 3s; it reads `.git/HEAD` (following a worktree's `gitdir:` file) with no subprocess.
- `SurfaceView.typeText` writes raw pty bytes through ghostty's `text:` binding action (Zig string
  escapes, `\r` = Enter). `ghostty_surface_text` is a *paste* (bracketed), so a newline in it
  won't run a command.

## Automatic Claude Code hooks (`ClaudeHooks.swift`, `Resources/claude-plugin/dealer`)

- Hooks reach Claude through a bundled **plugin named in `CLAUDE_CODE_PLUGIN_DIRS`**, set by
  `Pane.childEnvironment`. They do *not* go through a `claude` wrapper on PATH: rc files that
  prepend PATH would shadow one. docs/claude-code-states.md (#12) has the research.
  Don't switch to a wrapper or `--settings` without rereading that section.
- `pluginDirectory` resolves the bundle's `Resources/claude-plugin/dealer`, or, for
  `.build/<config>/Dealer`, the repo's copy. Edit the plugin in `Resources/`; `scripts/bundle.sh`
  copies it. Panes also get `DEALER_CLI` (this binary's absolute path), which the hook script
  calls, so hooks don't depend on `dealer` being on PATH.
- `hooks/dealer-hook.sh` must print nothing and exit 0. Output from a `PermissionRequest` hook
  is a permission decision. It keeps three guards: `DEALER_PANE_ID` set,
  `CLAUDE_CODE_ENTRYPOINT = cli` (skips nested `claude -p`), and `DEALER_CLAUDE_HOOKS != 0`.
  It uses `/usr/bin/plutil` for JSON, not `jq`. The self-test runs it against a stub `dealer`.
- At app launch, `main.swift` calls `InheritedEnvironment.scrub()` right after the CLI dispatch.
  It removes a parent Claude session's identity variables, every `CMUX_*` variable, and cmux's
  per-surface shim directories from `PATH`. A Dealer started from a cmux shell otherwise tells its
  panes they're cmux surfaces, and cmux-aware launchers then route Claude (and its hooks) to cmux. Keep it after that line: `dealer` run from a hook must keep its
  environment. Panes inherit the scrubbed process environment; `childEnvironment` can only add or
  override variables (ghostty `env_vars`), not remove them.
- The off switch is `Settings.agentInjectHooks` (`[agent] inject_hooks`), read at pane spawn. Running shells keep the
  environment they started with.

## Control socket (`ControlServer.swift`, `ControlHandler.swift`)

- `ControlHandler.handle` is a plain request → response function; the self-test drives it
  directly and only spawns the binary once for a real socket round-trip.
- Socket IO runs on background threads; `ControlServer.onMain` hops to main with a
  `CFRunLoopPerformBlock` in **default mode**, not `DispatchQueue.main.sync`. That lets requests run
  inside the self-test's nested default-mode waits, and keeps them out of drag tracking loops
  (event-tracking mode) so a script can't restructure the tree mid-drag. Don't switch it to common
  modes or the main queue.
