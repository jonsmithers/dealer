# Memory diagnostics

If Dealer is using a lot of memory (Activity Monitor's **Memory** column), capture a report
while it's high, before quitting:

- **Help › Capture Memory Diagnostics…** writes the report and shows it in Finder, or
- `dealer diagnose` in any Dealer pane prints the report's path.

Reports go to `~/Library/Logs/Dealer/dealer-diagnostics-<date>-<time>.txt`. Taking one takes
a few seconds. Attach the file to a GitHub issue (for example #43).

## What a report contains

- **Versions:** Dealer's version, when the binary was built, the HEAD of the checkout it was built
  from, the Ghostty pin and the linked libghostty version, the macOS version, the Mac model, RAM,
  CPU count, and app and system uptime.
- **Process memory:** `phys_footprint` (what Activity Monitor shows) and its peak, resident and
  virtual size, the thread count, and the number of open file descriptors.
- **Notification log:** whether `[notifications] log` is on, its path (`/tmp/dealer-notifications.log`)
  and size. Only the line about the log goes in the report, never the log's contents. `dealer diagnose`
  also prints this line to stderr.
- **Objects:** live counts of windows, workspaces, decks, tabs, panes, their views, and libghostty
  surfaces, next to how many the open windows actually hold. A count above that is a leak.
- **Panes:** one line per pane, numbered in tree order: its window, workspace, deck and tab
  *numbers*, whether the layout shows it (`visible`/`hidden`; `window-occluded` when its window is
  minimized, covered or on another Space), its grid (columns × rows), its pixel and cell size, and
  whether a process is running in it.
- **`vmmap --summary`** of Dealer (memory by region type: IOSurface and IOAccelerator are
  terminal renderer memory, MALLOC is ordinary heap).
- **`heap -s`:** the first 60 rows of Dealer's heap objects by class, by total size.

## What it never contains

No terminal contents, pane or tab titles, workspace names, working directories, commands or process
names, environment variables, or Dealer's object IDs. In the tool output your home directory is
replaced by `~` and your user name by `USER`.

## Opt-in: `dealer diagnose --leaks`

Also runs `leaks` against Dealer. It's slow on a large process, pauses Dealer while it runs, and
its output can quote bytes from leaked memory blocks, which may include terminal text. Read it
before you attach it.

## What's normal

Each terminal surface has its own renderer. While a pane is drawn, its renderer holds three
window-sized render targets (IOSurface), plus six more window-sized textures (IOAccelerator) if
your ghostty config sets `custom-shader`: at 3020×2036 px that's about 75 MB, or about 220 MB with
a shader, plus four threads. A pane that isn't drawn (a background tab or workspace, a parked deck,
or any pane of a minimized or fully covered window, #54) gives that memory back within a moment
and costs a few MB (#43, Ghostty since c4e16970a). A pane that was created hidden and never shown
keeps one window-sized buffer until it's first shown (#53). Scrollback adds at most ghostty's
`scrollback-limit` per pane (10 MB by default). libghostty's C API doesn't report memory per
surface, so the report can't break that down per pane. It lists each pane's pixel size instead.
