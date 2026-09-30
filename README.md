# Dealer

A small macOS terminal built on **libghostty** (Ghostty's embedding API) and Swift/AppKit,
implementing the *Panes and Decks* layout model:

```
Window
└─ Decks    split side by side or stacked; each has its own tab strip
   └─ Tabs    one active per deck
      └─ Panes  split inside a single tab; hidden when the tab is
```

A **pane** is owned by a tab. A **deck** owns tabs. Splitting always makes panes;
**promote** turns a pane into a deck, **fold** turns it back.

## Build & run

```sh
scripts/build-ghosttykit.sh      # builds GhosttyKit.xcframework from ~/git/ghostty (zig 0.15) into vendor/
scripts/bundle.sh                # swift build + wraps build/Dealer.app
open build/Dealer.app
```

Your normal Ghostty config (`~/.config/ghostty/config`) is loaded, and shell integration /
terminfo are borrowed from `/Applications/Ghostty.app` when it's installed.

## Keys

| Key | Action |
|---|---|
| ⌘T | New tab in the focused deck |
| ⌘D / ⌘⇧D | Split right / down (makes panes) |
| ⌘W / ⌥⌘W | Close pane / tab |
| ⌘1…⌘8, ⌘9 | Go to tab / last tab in the focused deck |
| ⌘⇧] / ⌘⇧[ | Next / previous tab |
| ⌘⇧P | **Promote**: pane → deck, hoisted to the window edge on its side, keeping its width |
| ⌘⇧F | **Fold**: deck → pane, back where it came from |
| ⌘⇧↑ | Select parent split (then ⌘⇧P promotes the whole group) |
| ⌘⌥←→↑↓ | Move focus by geometry, across decks |
| ⌘⇧↩ | Zoom: fill the deck, press again to fill the window, again to restore |
| ⌃⌘= | Equalize splits |
| ⌘N | New window |

Double-click a tab to rename it; middle-click or hover × to close it.

## Dragging

Drag a pane by its bar (shown once a tab has two panes; ⌥-drag grabs its parent split),
or drag a tab:

| Drop on | Pane | Tab |
|---|---|---|
| Edge of another pane | re-split beside it | rejoins as a split |
| Centre of another pane | swap the two | — |
| A tab strip | becomes its own tab (works across decks) | reorder / move to that deck |
| Window edge (past the decks) | promote to a new deck | becomes a new deck |
| Hover a tab | switches to it after a short delay | same |

## Session restore

Quitting saves the full window → deck → tab → pane tree (sizes, working directories,
tab names, focus) to `~/Library/Application Support/Dealer/session.json`; the next launch
restores it. Closing the last window by hand starts fresh next time.

## Self-test

```sh
swift build && DEALER_SELFTEST=quit .build/debug/Dealer
```

Replays the design's walkthrough (tabs, panes, rearranging, decks, deep promote, fold,
group promote, focus, zoom, swap, tab moves, snapshot round-trip) against a live window
and asserts the tree after each step.

## Layout

- `GhosttyRuntime.swift` – `ghostty_app_t`, config, runtime callbacks (clipboard, actions, close)
- `SurfaceView.swift` – NSView hosting a `ghostty_surface_t`: keys + IME, mouse, sizing, focus
- `Model.swift` – generic binary split `Node`, `Pane`, `Tab`, `Deck`
- `TerminalWindowController.swift` – all structural operations and layout
- `DragController.swift` – pane/tab drag & drop targets
- `Views.swift` – deck, tab strip, pane bar, dividers, overlays
- `Session.swift` – save/restore
