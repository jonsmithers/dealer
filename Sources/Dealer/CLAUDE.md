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
- **Occlusion has one rule (#54):** `SurfaceView` tells libghostty a pane is visible only when
  `setVisible` (the layout's say) is true AND its window is visible (`WindowVisibility`: not
  minimized, not covered, not on another Space; each SurfaceView observes its own window). Never
  call `ghostty_surface_set_occlusion` elsewhere. Occluded surfaces free their GPU swap chain but
  keep their size, shell, scrollback and attention; occlusion never resizes.
- **Surfaces start occluded (#53).** `layoutVisible` is false until the layout shows the pane;
  `layout(deck:)` calls `setVisible(true)` for every shown pane on every pass (after sizing it), not
  only on unhide. While occluded, `syncOcclusion` also turns off the layer's
  `needsDisplayOnBoundsChange`: ghostty's Core Animation display callback draws synchronously and
  ignores occlusion, so sizing a hidden pane (#45) would otherwise rebuild its swap chain and keep
  a window-sized frame as layer contents. `SelfTestHiddenBuffer.swift` checks both.
- **Out-of-view panes still get their real size (#45).** Background tabs are laid out in their
  deck's bounds (`sizeHidden`), and parked decks (other workspaces, zoom-hidden) at their
  workspace's unzoomed frame (`sizeParked`). A pane created out of view otherwise has no frame,
  so its surface is 1×1 cells and its output is lost on the resize when it's first shown.
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
- **Leaks keep shells running (#43).** A Pane that outlives its tree keeps its SurfaceView, the
  ghostty surface, its shell, four threads and ~50–70 MB of renderer memory. Two retainers were
  found and fixed:
  - Divider `onDrag` closures must capture values (`rect = d.splitRect`), never the `Node.Divider`
    struct, which holds its node strongly. Spare pooled dividers get `onDrag = nil`, and pools of
    decks that are gone are dropped in `layoutWindow`.
  - `windowWillClose` calls `releaseViews()`: AppKit keeps a closed NSWindow (and its views) past
    the controller, and a later layout pass then read freed decks through `TabStripView.deck`
    (`unowned`) and crashed. When AppKit frees the closed NSWindow itself isn't
    deterministic in the self-test. At delay 0, AppKit holds it until the step's outer
    main-queue block returns; animated, it takes seconds under load. So SelfTestMemory checks that
    views and surfaces are gone right after the close, and that a still-alive closed window holds
    no deck, pane or terminal views. It never waits for the window to be freed.
  - Counted classes call `LiveObjects.add`/`remove` in init/deinit (DiagnosticsCounters.swift).
    A new heavy class that should die with the model gets a `Kind`. Any new create/close path
    gets a cycle step in SelfTestMemory.swift, which fails when a count doesn't return to its
    baseline.
- The `wakeup_cb` and clipboard callbacks can arrive off the main thread. `wakeup` hops to main
  and calls `ghostty_app_tick`. `close_surface_cb` dispatches the close asynchronously to main;
  never free a surface synchronously inside a ghostty callback.
- `ghostty_init` and `ghostty_app_new` run once, in `GhosttyRuntime.start()`. Before that,
  `GhosttyResources.apply()` sets `GHOSTTY_RESOURCES_DIR` (shell integration, terminfo, themes;
  #39, #41). First valid one wins (valid = has `shell-integration/`):
  1. `DEALER_GHOSTTY_RESOURCES_DIR`, the explicit override, used as given; empty = none.
  2. The app's own `Contents/Resources/ghostty` (copied by `bundle.sh` from the pinned build).
  3. Self-test only: `vendor/ghostty-resources/ghostty` of this source tree (`#filePath`), then of
     the main checkout.
  4. An inherited `GHOSTTY_RESOURCES_DIR`, outside self-test mode only. Every Ghostty/Dealer pane
     exports one, possibly from another Ghostty version, so it can't be the override and ranks
     below the bundle.
  5. Launch Services' `com.mitchellh.ghostty`, then `/Applications`, then `~/Applications`.

  Finding none is logged, and so is a self-test without `vendor/ghostty-resources`. Keep `resolve`
  free of process state (the self-test drives it with temp dirs).
  - libghostty treats an empty variable as unset, then searches up from its executable for
    `Contents/Resources/terminfo/78/xterm-ghostty`, which finds the bundle's copy on its own and
    nothing for `.build/debug/Dealer`. TERMINFO is always `<resources dir>/../terminfo`.

## Tabs in the titlebar (`TitlebarTabs.swift`, #16)

- `placeTabStrips(frames)` runs in `layoutWindow` before the decks lay out, every pass. It
  reparents a top-edge deck's `strip` into the content view's titlebar row and sets
  `DeckView.stripInTitlebar` (the card then fills the deck). Every other deck gets its strip back,
  and strips in the content view whose deck isn't placed this pass are removed. That covers decks
  that were folded, closed or moved to another workspace: `detach(deck:)` removes the deck view,
  not a strip living outside it. Only strip views move; never recreate decks or surfaces for this.
  Match leftover strips by the strip's own identity: `TabStripView.deck` is `unowned`, and a
  leftover strip's deck may already be freed, so reading it there can crash.
- The clear line (`titlebarClearX`) is the zoom button, the sidebar toggle, or in top-bar mode the
  pill segment (`WorkspaceBarView.contentWidth`); the bar shrinks to its pills in this mode so it
  doesn't cover strips. New titlebar chrome must push `titlebarClearX` right.
- Titlebar clicks are decided by the window server *before* the app sees them: wherever the view
  under the pointer answers `mouseDownCanMoveWindow == true` (NSView's default for non-opaque views),
  a press drags the window and never reaches the view. Every interactive view that can sit in the
  titlebar row (tabs, buttons, pills, rows) must return `false`; `TabButton` didn't (#27). An
  in-process `window.sendEvent` can't reproduce this, so the self-test asserts the property.
- Titlebar tabs have two drag zones, like macOS's native titlebar tabs (#27): press-and-drag on a
  tab's top half moves the window, on its bottom half (and the ×) drags the tab; a click anywhere
  selects it. `mouseDownCanMoveWindow` is one answer per view, so the split is done by the tab's
  hover tracking turning `window.isMovable` off over the bottom half and back on elsewhere (and
  `placeTabStrips` restores it when no strip is in the titlebar). Top-half presses that reach the
  app go to `performDrag` once they move. The window-server side can't be self-tested; the zone
  split and the isMovable switching are.
- Empty strip space in the titlebar drags the window (`performDrag`) and runs the system
  double-click action (`AppleActionOnDoubleClick` from the global domain: a macOS setting, not a
  Dealer one). DragController checks titlebar strips before the top-edge promote band they sit in.
- Tests: the strip's frame must equal its deck's x-range clipped at the clear line. For the
  empty-space hit test, pick a point after the strip's last control; with several tabs a strip can
  be full.

## Tab style (`TabShape.swift`, #84)

- `[tabs] style`: "connected" (default) or "pill", read live through `TabStyle.current`. Both go
  through one drawing path: a `ChromeShape` (a rounded rect, or a connected tab: rounded top,
  square bottom, outline open at the bottom) is what the tab's fill, `ColorStyle.drawTint` and
  `AttentionStyle.draw` follow. Don't add a second tab drawing path; extend the shape. Other
  elements pass `cornerRadius:`, which forwards to `.rounded(r)`.
- No seam: a connected strip is `style.overlap` (1pt) taller than its row and sits **above** the
  card (in-deck: added after `content`; titlebar: `raiseTitlebarStrips()` after the decks are
  added), so the active tab paints over the card's 1pt top border. The strip's `hitTest` gives that
  row back to the pane except under the active tab. Height math (`chromeSize`) is unchanged.
- The card's top corners go square through `DeckView.squareTop` (`maskedCorners`; the layer is
  flipped, so max-Y is the bottom). PixelProbe's offscreen render ignores `maskedCorners`, so the
  self-test checks the layer property; check corners by eye in screenshots.
- Titlebar strips connect too (the user's call): the titlebar row ends where the top deck's card
  begins.
- On a translucent window a connected active tab follows one switch, `TabStyle.translucent` (#87):
  `.opaque` (default) fills it with the opaque background like a pill; `.tinted` makes it part of
  its terminal (`TabButton.connectedFill` paints what the terminal paints, background at the
  opacity or nothing under glass, `layoutBackdrop` cuts it out of the chrome with its card,
  `CardHole`) plus `TabButton.connectedTint` (foreground at `TabStyle.activeTint`); `.clearInactive`
  is `.tinted` without inactive pills. `connectedMatchesTerminal` is derived from it. Pill tabs stay
  opaque (#67) regardless.
- The active tab's underline (#86) is the deck accent, or its `Tab.color`, in every window, one
  deck included (`TabStripView` always sets `accent`; there is no deck-count gate). It sits at the
  bottom of `bodyRect` (`underlineRect`): for a connected active tab that covers the overlap row, so
  the line runs into the terminal; a pill's is unchanged. It's drawn after the fill and tint and
  before `AttentionStyle.draw`, whose open bottom adds no stroke to it (only its 10% tint lies
  over it). It's a line, not a chrome fill, so it never goes through `Theme.fill` and stays opaque
  on a translucent connected tab. Tests: `SelfTestTabStyle.swift` (`DEALER_SELFTEST_ONLY=tab style:`),
  the one-deck check in the walkthrough (`singleDeckUnderlineProblem`).

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
- Groups (#80, `WorkspaceGroups.swift`): `workspaces` stays one flat list (⌃1–9 and the menus
  count it), and a `WorkspaceGroup` exists only as its members' `Workspace.group`, so it vanishes
  with its last member. Members are always contiguous: every reorder goes through
  `setWorkspaceOrder`, and `insert(workspace:at:)` and `restore` through `Workspace.contiguousGroups`.
  Both switchers lay out `SwitcherLayout.entries` (headers, plus members unless collapsed) and drag
  through `SwitcherDragHost`/`SwitcherLayout.drop`; compute entries on demand, never store them
  in a view (AppKit keeps a closed window's views, and stored entries leaked its workspaces, #43).
  A collapsed header (`GroupHeaderView`) carries its members' rolled-up attention, spinner and the
  selection outline; groups have no color. Session: `WindowSnapshot.groups` +
  `WorkspaceSnapshot.group` (an index), both optional, so files decode both ways.
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
- Both mark the selected workspace through `SelectionStyle` (WorkspaceSwitcher.swift; #52, and
  again after #90's edge bar was reversed): a neutral `Theme.text` outline (`drawOutline`,
  `workspaceSelectionOutline` = the attention outline's width and path) and
  `Theme.Fonts.workspaceActive`; pills (not sidebar rows) also get the `Theme.workspaceSelection`
  fill (`drawFill`), inset like the color tint. Sidebar rows and headers draw attention with
  `outline: false` (#91: a large dot, `sidebarDotSize`, centred on the row, plus the tint), so their
  selection outline never yields and is drawn **after** `AttentionStyle.draw`, whose tint would
  otherwise wash over it. On pills and label pills it yields to an attention outline (selection
  alpha = 1 − attention alpha, cross-fading back during #34's fade) and is drawn just **before**
  `AttentionStyle.draw`. Colored sidebar rows have a 3pt chip at the left edge (`chipRect`,
  `ColorStyle.drawChip`), selected or not; pills have none. Change both switchers together;
  `SelfTestSelection.swift` checks both. Sidebar attention is checked with
  `PixelProbe.hasWaitingDot`/`hasFailedDot` (large dot, no outline), never `isWaitingOutlined`.

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
  debounce (keeps it independent of how the caller runs the main loop).
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
- Workspaces restored but never shown still have their deck views in the window: `sizeParked` (#45)
  adds every parked deck to the content view, hidden, on each layout pass. So ghostty actions from
  their panes (bell, OSC notifications, keybinds) find the window controller once the window has
  laid out.

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
  attention outline stays outside it), a tab's underline, and `ColorStyle.drawChip` (sidebar rows
  only; pills have no chip since #90), and call `AttentionStyle.draw` after them. The self-test
  checks that a waiting-blue workspace or tab doesn't read as outlined (or, on the sidebar, dotted).
- Swatches come from `Theme.swatches` (light/dark variants, or `[colors] palette`). Parse
  user-given colors with `Theme.parseColor` (CLI and settings share it).
- `autoAssignColor` runs from `insert(workspace:)`, so it covers every workspace created after the
  window's first: menus, CLI, and moves into a new workspace.

## Self-test sections

- Feature steps live in their own files (e.g. `SelfTestWorkspaces.swift`) and are added through
  the `SelfTestKit` passed from `runSelfTest`, one call line per section.
- **Steps wait on conditions, never on fixed delays (#47).** The runner doesn't pause between
  steps (`DEALER_SELFTEST_DELAY` defaults to 0 and exists only to watch the UI). Synchronous
  controller calls plus `layoutNow()` need no wait. Anything asynchronous (a shell, ghostty's
  actions, an animation's end, AppKit's deferred release, the settings watcher) is waited for in
  the step with `SelfTest.waitUntil(timeout:_:)` (returns whether it held) or
  `SelfTest.waitUntil(_:timeout:_:)` (a failure message naming the condition). Default timeout 5 s;
  shell steps use 10–20 s, since a timeout only costs time when the behavior is broken. Don't
  hand-roll `RunLoop.run` loops, and don't rely on time passing between steps: a step that
  passes only because an earlier step took long (e.g. #34's 0.3 s reveal window) is a bug.
  - Steps start from a run-loop **timer**, not a main-queue block, so a wait drains the main
    queue: ghostty's actions (`wakeup_cb` → `DispatchQueue.main.async` → `ghostty_app_tick`),
    `onClose`/`onTitle`, and `setAttention` from shell-driven events all arrive inside it. The
    helper also ticks ghostty each slice. The `runner:` step asserts this.
  - Before typing into a pane created in the same step, call `surface.waitForShell()` (SelfTest.swift,
    #62): it types a sentinel echo until the shell answers. A line typed into a shell that is still
    starting was sometimes lost in loaded full runs.
  - Panes in an inactive workspace aren't laid out, and their shells reported no foreground
    process in testing; activate the workspace before checking one.
- **Pixel checks go through `PixelProbe` only** (SelfTestPixels.swift): `sample(_:at:)`, `pixels` (raw bytes for "renders identically"),
  `distance`, `matches`, `isWaitingOutlined`. Never call `cacheDisplay`/`colorAt` in a check
  directly. Two traps it handles:
  - `bitmapImageRepForCachingDisplay` gives a display-space bitmap for a window-backed view and a
    Generic RGB one for a detached view. The latter clips saturated sRGB colors (`#aa00ff` reads
    0.22 off). `sample` renders into its own sRGB bitmap instead.
  - `colorAt` can label display-space components "calibrated RGB"; converting them as labeled
    is off by up to ~0.25. `sample` re-tags mislabeled components with the bitmap's color space.
- `PixelProbe` renders at a fixed 2x (`PixelProbe.scale`), never the window's
  `backingScaleFactor` (#48): on a 1x display the failed dot's 1.44pt `!` covers no whole pixel and
  a fixed sample point landed on its antialiased edge. Sample points must be fully covered at 2x
  (a 1pt line at `+0.5` is; at 1x it isn't unless the frame is whole points). For thin glyphs,
  take the best pixel in the shape's rect (`samples(_:in:)`, as `bangProblem` does) rather than
  one point. `atEachScale` reruns a check at 2x and 1x so 1x regressions show on Retina-only
  machines; the `pixels:` steps and the failed-dot steps use it.
- Compare with `PixelProbe.matches` (tolerance 2/255, alpha included) against the exact expected color, e.g.
  `Theme.attentionWaiting`. Reads are exact for solid fills. Don't loosen the tolerance to make a
  check pass; that hid the bug above. The `pixels:` steps fail first if the probe regresses.
  `Theme.withBackground(_:_:)` checks light/dark variants of draw-time colors on a detached view.

## Styling (`Theme.swift`)

- `Theme` is the single source for chrome colors, metrics, fonts and animation timings. Don't
  hard-code colors or sizes in views. `Palette` is only a set of legacy forwards to `Theme`.
- **Chrome shade (#87).** `Theme.chrome` is `chromeColor(background:foreground:shade:)` with
  `shade` = `[colors] chrome_contrast` (`Settings.chromeContrast`, −1…+1, default +0.3; out of range
  is reported with the range, e.g. the old WCAG-style 1.35). Positive: `bg.mixed(with: pole, m)`,
  the pole being black when `isDark`, else white. Negative: `bg.mixed(with: fg, |m| *
  maxChromeMix)` (0.5). A black dark theme or white light one can't deepen. Its reload calls
  `applyTheme()` (`settingsDidChange`), since the chrome is copied into the window background and
  layers. Don't bring back a contrast-target solve: it flipped direction past what darkening could
  reach (Kanso Mist at 1.38:1). `Theme.hover` is `chrome.mixed(with: surface, 0.5)`, between in both
  directions. Everything derived from `chrome` (`paneBar`, `textMuted`/`textFaint`,
  `workspaceSelection`, `accentNeutral`) moves with it. `SelfTestTabContrast.swift`
  (`tab contrast:`) checks: monotonic over the range through the setting, 0 = background, hover
  between, and at the default dark strips ≥ 1.08:1 off the active tab (light themes and
  black/near-black are nearly flat there; only their direction is checked) and attention outlines
  ≥ 3:1 in every theme; plus real tab buttons, a live reload, the translucent options. Negative
  values raise the chrome toward the foreground, and with a bright foreground the failed red drops
  under 3:1 (≈2.5:1 at −0.3 in Ghostty's default dark and Nord).
- **The theme changes live (#33).** `Theme.load` runs at launch, then `Theme.reload` runs from
  every CONFIG_CHANGE that ghostty sends (after ⌘⇧, / `reload_config`, or a color-scheme switch),
  and posts `Theme.didChange`. Each window's `applyTheme()` (ThemeReload.swift) walks its views,
  including parked decks and detached switchers, calls `applyTheme()` on every `ThemeApplying`
  view, and redraws everything. **Any view that copies a Theme color into a layer, a label or a
  tint must conform to `ThemeApplying` and set that color in `applyTheme()`**, called from its
  init. Colors read in `draw(_:)` need nothing. Transient colors set by `show(…)` calls (drop
  highlight, strip marker) are fine.
  - `SelfTestReload.swift` scans every visible layer and control for a color of the previous theme,
    so a new stale copy fails there.
  - `GhosttyRuntime.config` is the raw loaded config (used for soft reloads and `ghostty_config_get`
    lookups). Theme colors come from the *resolved* config in CONFIG_CHANGE. A config with
    diagnostics is refused on reload (the old one stays) and listed in the settings banner.
  - Reload work hops to main with `CFRunLoopPerformBlock` in default mode, not the main queue,
    for the same reason as `ControlServer.onMain`.
- **Transparency (#67, `WindowTransparency.swift`).** `Theme.transparency` is the one read of
  `background-opacity`/`background-blur` (glass = the C API's -1/-2 sentinels; recheck on a pin
  bump). Translucent windows: chrome *fills* go through `Theme.fill(_:)` (alpha = opacity; the
  color itself when opaque, so opacity 1 renders byte for byte as before); text, outlines, dots,
  glyphs and the spinner never do. Tab buttons are the exception (the user's call): fully opaque, with a solid `Theme.chrome` pill for inactive tabs while translucent (connected tabs: see `TabStyle.translucent`, #87). Nothing opaque may sit under a terminal: the content view's fill
  moves to `WindowBackdropView`'s chrome view, which cuts the deck cards out, the deck card and
  `PaneView` drop their backgrounds, and pane `DividerView`s paint their own gap
  (`paintsGap`). A new chrome fill uses `Theme.fill`; a new view under the panes must stay clear
  while translucent. `SelfTestTransparency.swift` (`DEALER_SELFTEST_ONLY=transparency:`).
  Glass (macOS 26+, `#if compiler(>=6.2)`): an `NSGlassEffectView` at the bottom of the backdrop,
  under its chrome view, tinted with the background at its opacity (Ghostty's
  `TerminalViewContainer`); `applyTheme` attaches or removes it synchronously on every reload.
  Elsewhere glass falls back to a radius-20 blur (`WindowBlur`, since ghostty's blur call would
  pass the -1/-2 sentinels to the window server).
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
  `GhosttyRuntime.followSystemAppearance` tells ghostty the macOS appearance (app and every
  surface, and new surfaces at creation), so a conditional `theme = light:…,dark:…` follows it
  (#33). Chrome light/dark still follows the resolved background's luminance.
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

- `setAttention(_:on:raiseOnly:title:subtitle:body:event:)` is the only writer of `Pane.attention` besides
  `didFocus`, which clears it (so do `windowDidBecomeKey` and `Presence.screenUnlocked`). Presence
  (#71, `Presence.swift`) is the one source of "is the user there": `Presence.inFront` (Dealer
  active, screen unlocked), `userPresent()` (in front and this window key) and `isLookingAt(pane)`
  (present, focused, drawn). A locked screen counts as away. `didFocus` clears only on a focus
  change while `userPresent()`, or a re-focus while `isLookingAt`; otherwise the mark is kept
  (`attention:kept`) until the user is back. `finishChange` re-focuses the already-focused pane
  after any background change (e.g. a `dealer run` job pane closing), and that must not wipe a mark.
  Desktop notifications are suppressed whenever `Presence.inFront`, whatever the window or pane;
  the marks carry it. Self-test seam: `Presence.override` (facts: app active, locked, key window).
  With no override, self-test mode counts focus changes as seen (`focusCountsAsSeen`), as before
  #71, so steps that clear marks by focusing keep their meaning; `SelfTestPresence.swift` sets the
  override. Authorization is re-read on every activation and before a post while not allowed
  (`AttentionNotifier.refreshStatus`, test seam `statusReader`). It refreshes
  chrome and posts the macOS notification; don't assign `pane.attention` elsewhere.
- Automatic sources (bell, OSC 9/99/777, long `COMMAND_FINISHED`) pass `raiseOnly: true` so they
  never downgrade `waiting`; explicit `dealer notify` sets the state exactly (including `none`).
  A non-`none` state is dropped when the user is already looking at the pane (`isLookingAt`).
- Tab/deck/workspace attention is computed (max over children), never stored; badges pick it up
  from `refreshChrome()`. The ring is a sublayer named `dealer.attentionRing`, and the self-test
  finds it by that name.
- `failed` (#29) is the top state: failed > waiting > done > unread, for roll-up and ⌘⇧U. It's
  drawn like waiting in `Theme.attentionFailed` (red, light/dark), and its dot carries a `!`
  (`AttentionStyle.drawBang`). `PixelProbe.isFailedOutlined` checks it. Sources: `dealer run`
  failures (ControlJobs), `dealer notify --state failed`, the plugin's StopFailure hook (unless
  `[agent] errors_as_failed = false`, exported as `DEALER_CLAUDE_ERROR_STATE`), and COMMAND_FINISHED
  with a non-zero exit (`commandFinishedAttention`, `[attention] failed_commands`).
- The waiting dot carries a knocked-out `?` (`AttentionStyle.drawQuestion`, #65), the only thing that
  tells it from an outlined *done* (#61), which stays a bare dot. Dots are 8pt on tabs, rows and
  pills (`Theme.Metrics.switcherDotSize`) so both glyphs read at 1x; `SelfTestWaitingGlyph.swift`
  checks the `?` the way #48 checks the `!`.
- Shell-driven events (ghostty actions, socket requests from a shell) reach `setAttention` through
  `DispatchQueue.main.async`. A `SelfTest.waitUntil` in the same step sees them (the runner starts
  steps from a timer, #47).
- Fade-out (#34): elements never draw `pane.attention`/`attention` directly. They draw
  `attentionFade.shown` at `attentionFade.alpha` (`AttentionFadeState`, one per PaneView ring,
  TabButton, WorkspaceRow and WorkspaceButton), fed the model value on every refresh with the
  element's subject (pane, tab or workspace). The subject must be set before `attention` in a
  reload (`b.tab = tab` then `b.attention = …`), so a recycled view showing a different subject
  jumps instead of fading. A clear to `none` fades over `AttentionFade.duration`, plus
  `revealHold` when it follows `reveal(_:)`. A raise cancels it, Reduce Motion drops it, and one
  common-mode timer (`AttentionFader`) ticks only while something fades. Colors are read from
  `Attention.color` (Theme) on every draw and tick, never cached. Fades are off in self-test
  mode (`AttentionFade.enabled`) so checks see clears at once; SelfTestFade.swift turns them on.
  **Animations in the self-test run at real speed (#47's choice):** the fade steps assert the
  timing itself (solid during the hold, part-transparent mid-fade, gone after), so they sample it
  part-way with short real-time waits and wait for the end state with `waitUntil` and the same
  deadline. A time scale would make the mid-fade samples fragile at a 60 Hz tick for about 2 s
  saved. Animations whose timing isn't under test (drop settle, #28) are only waited out with
  `waitUntil` on their end state. A fade step must first wait out the reveal window
  (`AttentionFade.timing().hold == 0`) if a ⌘⇧U step may precede it.
- Look (#7, #61): `Attention.outlined` is the single answer to "outline or dot", and `Attention.color`
  the colour; every drawer (pane ring, `AttentionStyle`, the status line)
  reads them, never the state directly. `waiting` and `failed` are always outlined; `done` follows
  `[attention] done` (default "outline") and `unread` follows `[attention] unread` (default "dot"),
  read live. Outlined means the pane ring plus an outline, tint and dot on the tab and workspace entry
  (on the sidebar, #91: the tint and a large dot, never an outline; every state there gets the large dot);
  an outlined done/unread is exactly waiting's look, in `Theme.attentionWaiting` (adaptive blue). A
  dot state is a muted dot only (`Theme.attentionDone` = `textMuted`). Priority doesn't change with
  the look. A settings reload of those keys calls `applyTheme()` so unchanged marks redraw
  (`SelfTestAttentionStyle.swift`). Chrome elements draw attention only through
  `AttentionStyle.draw(_:in:cornerRadius:dotRect:)`, called last in `draw(_:)` so the outline
  sits on the element's outer edge. The self-test samples the top edge's centre pixel
  (`PixelProbe.isWaitingOutlined`), so don't inset the outline or draw it in a sublayer.
- "running" is `Pane.isReportingProgress` (OSC 9;4 from `GHOSTTY_ACTION_PROGRESS_REPORT`), not a
  process check; attention outranks it in `agentState`. *Who* reports it (#81) is a process check:
  `ProgressSource.note` records each report and decides Claude-or-not from the foreground process
  group's argv/executable path (never `p_comm`: a native Claude's is its version), looking again
  only when the group changes, with Claude's `◐`/`◑` title as the fallback.
- Progress nobody clears (#83, `ProgressSource.armTimeout`/`expire`): every report restarts a
  per-pane 15 s timer (Ghostty.app's interval); when it runs out, progress stays only while the
  group that sent the last report is still the foreground, and is checked again 15 s later.
  Not a plain timeout: Claude Code sends 9;4;3 once per turn. Off in self-test mode
  (`timeoutEnabled`), so steps that set progress by hand keep it; `SelfTestProgressTimeout.swift`
  (`progress timeout:`) turns it on with a 1 s interval. `Pane.isWorking` is that rolled up
  (`agentState == .running`, so a *waiting* pane doesn't count even though Claude keeps progress set
  while a dialog is open), and `Tab.isWorking` / `Workspace.isWorking` are the max over their panes,
  computed like attention's roll-up. `GitInfo.lookup` is main-thread only and
  caches for 3s; it reads `.git/HEAD` (following a worktree's `gitdir:` file) with no subprocess.
- `SurfaceView.typeText` writes raw pty bytes through ghostty's `text:` binding action (Zig string
  escapes, `\r` = Enter). `ghostty_surface_text` is a *paste* (bracketed), so a newline in it
  won't run a command.

## Program status, OSC 7501 (`ProgramStatus.swift`, #89)

- Reports arrive as GHOSTTY_ACTION_PROGRAM_STATUS, which only exists with Dealer's runtime patch to
  libghostty (`scripts/ghostty-build/`, "Runtime patch"): the report body Ghostty already validated,
  or an empty body for a full reset (RIS). libghostty answers the support query itself; Dealer can't,
  because its reply would land after the terminal's answer to the `CSI c` that follows the query.
  `dealer status` builds a body and goes through the same `ProgramStatus.receive`, so
  `ProgramStatus.parse` implements the spec's validation itself (and the self-test checks it
  without a surface).
- **Text is sanitized in one place**, `ProgramStatus.sanitize` (Cf characters such as bidi
  overrides and zero-width ones removed); records only ever hold sanitized `title`/`msg`.
- `ProgramStatusStore` (one per pane, `Pane.programStatus`) is the pure model: replace semantics,
  `clear` by id prefix, LRU eviction at `maxRecords`, roll-up (`summary`: error > blocked > done >
  working > idle), `app` inheritance. `agentState` reads its summary right after attention, so a
  blocked record shows as *waiting* even when its mark was skipped because the user was looking.
- **7501's attention is a level, not an event** (the user's call on #89): `ProgramStatus.update`
  raises (`raiseOnly`) when the records ask for more than `Pane.programAttention`, and lowers
  only a mark equal to what it raised itself (`blocked` → `working` drops *waiting*; a `dealer
  notify` mark is never lowered). Done and error records are dismissed when the mark is cleared
  (`Pane.attention`'s didSet) or when they arrive while the user is looking; a seen blocked record
  stays and doesn't mark again until something lower replaces it.
- Working and blocked records go at the next prompt (COMMAND_FINISHED, `promptReturned`) or when
  the process group that reported them leaves the foreground (`armExitCheck`, polled every 2 s
  while such records exist; off in self-test mode unless a step turns it on).
- Once a pane has sent 7501, its OSC 9;4 is ignored (and its 9;4 progress dropped) until a full
  reset (`ProgramStatusStore.inUse`), as the spec says; the #83 timeout doesn't apply to records.
- Not done: the spec's rate limit on external effects is only the level rule above (a mark, and so
  a notification, needs the level to rise).

## The working spinner (`RunningSpinner.swift`, #64)

- The only continual animation in the chrome, in the leading slot of a tab button, sidebar row,
  pill or collapsed group header that holds a working pane. Which one is a `WorkingMark` (#81,
  AgentStatus.swift): Claude's sprite (`SpinnerAnimation.claude`, #73) for Claude Code, a turning
  arc for any other program, a ring filled to the percentage of a determinate report.
  Roll-ups go through **one helper**, `WorkingMark.strongest` (Claude > arc > ring, the least
  complete ring); tabs, workspaces and group headers all use it. Elements hold a
  `working: WorkingMark?` (`isRunning` is derived) and draw through `RunningSpinner.draw(_:in:phase:)`.
- **It is never a colour.** It draws in the element's own title colour, because colours and
  outlines on chrome mean attention (#7, #9). It is orthogonal to attention and sits on the
  opposite side of the element from the dot, so the two never collide; a *waiting* pane doesn't
  spin (`isWorking` reads `agentState`).
- Elements own a `RunningSpinnerState`, fed `set(_:)` on every refresh (the `isRunning` properties,
  set from `reload()` like `attention`), and draw through `RunningSpinner.draw` only — one drawer,
  like `AttentionStyle`. A tab keeps its width and gives the slot to its title (a strip must not
  reflow whenever an agent starts or stops); a pill, which is sized to its content, grows by
  `RunningSpinner.slot`, as it already does for the attention dot.
- `SpinnerTicker` is one timer in the common run-loop modes for every spinning element, running
  only while something spins. Unlike `AttentionFader` it holds its states **weakly**: a fade ends
  and unregisters itself, but a spin has no end, so a strong reference would keep a closed pane's
  button, its state and the timer alive forever (#43). Keep it weak, and keep the
  "closed workspace leaves no registration" steps.
- Switches: `RunningSpinner.animating` is off in self-test mode (on for demos), like
  `AttentionFade.enabled`, and Reduce Motion leaves a standing asterisk and no timer
  (`RunningSpinner.spins`). `phaseOverride` renders a chosen frame for pixel checks.
  Tests: `SelfTestSpinner.swift` (`DEALER_SELFTEST_ONLY=spinner:`, self-contained) and
  `SelfTestWorkingMarks.swift` (`marks:`, self-contained; `ProgressSource.foregroundOverride` fakes
  the process table, and a live step uses a `claude` symlink to `/bin/sh`).

## Keeping the display awake (`Caffeinate.swift`, #69)

- `Caffeinate.shared` is the only owner of the power assertion (`kIOPMAssertPreventUserIdleDisplaySleep`,
  no child `caffeinate`) and of its grace timer (common run-loop modes). "Working" is the spinner's
  `Pane.isWorking`, counted over every window's panes in `Caffeinate.countWorking`; never a second
  definition. It recounts at the spinner's change points (end of `refreshChrome`, `finishChange`,
  a window closing, `Settings.didChange`), not on a timer, so a new way for `isWorking` to change
  must end in `refreshChrome()` like the others.
- The cup (`CaffeineIconView`) follows `Caffeinate.didChange`. Its width is reserved at the right
  end of the titlebar row (`titlebarTrailingX`) whenever the setting is on, held or not, so strips
  and pills don't reflow as agents start and stop; new titlebar chrome must end before it.
  Its tooltip is one rect it owns (`addToolTip`, text from `Caffeinate.toolTip()` when shown),
  never `toolTip =` in layout: re-setting it re-adds the rect and restarts the hover delay.
- A closed window never lays out again (`isClosed`, set in `windowWillClose`): a notification
  reaching its not-yet-freed controller used to put back the deck views `releaseViews` took out.
  Tests: `SelfTestCaffeinate.swift` (`DEALER_SELFTEST_ONLY=caffeinate:`, self-contained; checks
  IOKit's own list via `Caffeinate.ownAssertionNames`).

## Notification decision log (`NotificationLog.swift`, #56)

- `[notifications] log` (read live) appends one line per attention/notification decision via
  `NotificationLog.decision(pane:event:outcome:reason:title:subtitle:body:)`, a no-op when off. Lines are
  built on main; the append and rotation (`maxBytes`, renamed to `.1`) run on a serial queue.
- **Every new path that sets, skips, clears or posts must log, and every "no" needs a reason.**
  `setAttention` takes an `event:` label (`bell`, `notify`, `claude:<event>`, `job-done(status=N)`)
  and logs set/skipped itself; `post` logs posted/suppressed; `clearAttention(_:cause:)` and
  `reveal(_:cause:)` name what cleared it (`NotificationLog.clearCause` carries the reveal's cause
  into `didFocus`). Only logging was added: the decisions themselves are unchanged.
- **Withdrawing banners (#78):** `Pane.attention`'s didSet is the one place a clear is seen; on a
  clear it calls `AttentionNotifier.withdraw`, which removes `pane-<id>` (delivered and pending)
  only if `deliver` posted one this run (`posted`). Closed panes are swept by `withdrawClosed()`
  from `finishChange` and a window's `onClose`. Each withdrawal logs `notification:withdrawn`,
  named by `NotificationLog.clearCause` (`withClearCause` sets it for focus and `clearAttention`).
  Self-test/unbundled runs record it in `withdrawals` without calling UN; `SelfTestNotifyRemove.swift`
  stands in for posts with `notePosted`.
- The hook script labels its `dealer notify` calls with `--internal-log-source claude:<event>`.
  The flag is deliberately undocumented (not in `dealer help` or docs/cli.md); keep it hook-only.
- The self-test writes to a temp path (`NotificationLog.path`), never `/tmp/dealer-notifications.log`.
  `SelfTestNotificationLog.swift` checks the lines; keep its fragments in sync with log wording.
- Privacy: no environment values or terminal contents; titles/bodies truncated (`fieldLimit`).

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
- The plugin also teaches Claude the CLI: `skills/dealer/SKILL.md` (the guide Claude loads; keep
  it in step with docs/cli.md when a command changes) and `hooks/session-start.sh`, whose stdout
  *is* the point (Claude Code adds a SessionStart hook's output to the session's context): it
  names the caller's pane IDs from `dealer identify` and the skill. It keeps the pane and
  `DEALER_CLAUDE_HOOKS` guards but not the entrypoint one, so `claude -p` gets the context too.
  No install step and nothing in `~/.claude`, unlike Rex's `rex skill setup` (the model for it).
- `create --command CMD` runs `$SHELL -l -c 'exec CMD'` (`ControlHandler.loginShellCommand`): ghostty
  starts a command with no startup files, so from the Finder it had launchd's PATH and Homebrew's
  `nvim` wasn't found. Login, not interactive (`-i`), is the user's call.
- `dealer read` goes through `SurfaceView.readText` (ghostty's `read_text`, ACTIVE or SCREEN
  points), the one reader; the self-test's `screenText` forwards to it. `--wait` is a client-side
  poll in `CLI.run`, so the handler stays a quick read on main.
- At app launch, `main.swift` calls `InheritedEnvironment.scrub()` right after the CLI dispatch.
  It removes a parent Claude session's identity variables, every `CMUX_*` variable, and cmux's
  per-surface shim directories from `PATH`. A Dealer started from a cmux shell otherwise tells its
  panes they're cmux surfaces, and cmux-aware launchers then route Claude (and its hooks) to cmux. Keep it after that line: `dealer` run from a hook must keep its
  environment. Panes inherit the scrubbed process environment; `childEnvironment` can only add or
  override variables (ghostty `env_vars`), not remove them.
- The off switch is `Settings.agentInjectHooks` (`[agent] inject_hooks`), read at pane spawn. Running shells keep the
  environment they started with.

## Diagnostics (`Diagnostics.swift`, #43)

- One implementation, `Diagnostics.capture(_:)`, behind Help › Capture Memory Diagnostics… and
  `dealer diagnose`. docs/diagnostics.md lists what it collects. **Keep the two in sync**, and keep
  it private: counts and sizes only, panes numbered in tree order, tool output passed through
  `redact`. The CLI step in SelfTestCLI.swift checks that test titles, cwds and the home path are
  absent. `leaks` runs only with `--leaks`.
- libghostty's C API has no per-surface memory figure, and `ghostty_config_get` can't read `usize`
  keys such as `scrollback-limit`.

## Control socket (`ControlServer.swift`, `ControlHandler.swift`)

- `ControlHandler.handle` is a plain request → response function; the self-test drives it
  directly and only spawns the binary once for a real socket round-trip.
- Socket IO runs on background threads; `ControlServer.onMain` hops to main with a
  `CFRunLoopPerformBlock` in **default mode**, not `DispatchQueue.main.sync`. That lets requests run
  inside the self-test's nested default-mode waits, and keeps them out of drag tracking loops
  (event-tracking mode) so a script can't restructure the tree mid-drag. Don't switch it to common
  modes or the main queue.
