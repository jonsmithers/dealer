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
- **Objects:** live counts of windows, workspaces, decks, tabs, panes, their views, and libghostty
  surfaces, next to how many the open windows actually hold. A count above that is a leak.
- **Panes:** one line per pane, numbered in tree order: its window, workspace, deck and tab
  *numbers*, whether it's on screen, its grid (columns × rows), its pixel and cell size, and
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

Each terminal surface has its own renderer, whether its pane is on screen or in a background tab
or workspace. Measured at the pinned Ghostty, in a full-screen window on a Retina display
(2336×1340 px per surface), each pane costs about **65–70 MB**, almost all of it GPU buffers
(IOSurface, IOAccelerator), plus four threads. The cost grows with the window's pixel size.
Scrollback adds at most ghostty's `scrollback-limit` per pane (10 MB by default). So 70 panes
in a big window come to about 5 GB with no leak at all. libghostty's C API doesn't report memory
per surface, so the report can't break that down per pane. It lists each pane's pixel size instead.
