# Orchestrator hand-off: Dealer

Read this before orchestrating agents on this repo. It complements the generic
[`orchestrate-issues`](https://github.com/jonsmithers/orchestrate-issues) skill and the code-level
rules in `CLAUDE.md` / `Sources/Dealer/CLAUDE.md`. It covers what the orchestrator needs that those
don't: where things live, how merging works here, the user's preferences, and the history that
explains current decisions. Keep it current.

## Where things are

| What | Where |
|---|---|
| Main checkout | `~/git/myterm` (local dir still has the old name; GitHub repo is `jonsmithers/dealer`, **private**) |
| Agent worktrees | `~/git/myterm-wt/<slug>`, branch `issue-<N>-<slug>`, plus `vendor/GhosttyKit.xcframework` symlinked from the main checkout |
| Coordination | `~/git/myterm/.git/coord/`: `BOARD.md`, `merge.sh`, `last-pass-count`. **Not `/tmp`:** macOS cleaned it twice and deleted the board and merge script. |
| User's to-do list | `~/git/myterm/TODO.md`, excluded via `.git/info/exclude`. The user annotates it inline. |
| User scratch files | Untracked files in the repo root such as `new-prompts.txt` are the user's drafts. Never commit or delete them without being told. |
| Demo media | Orphan branch `media` (GIFs/MP4s), checked out at `~/git/myterm-wt/media-branch`. Never on master. Regenerate with `scripts/record-demo.sh`, then `--publish` (see CLAUDE.md). |
| Pinned Ghostty build output | `vendor/GhosttyKit.xcframework` and `vendor/ghostty-resources/` (#41) in the main checkout, both git-ignored and shared by worktrees (the self-test finds the main checkout's resources by itself). Agents build at the pin in a `git clone --shared` with `build-ghosttykit.sh --out <tmp>`; the lead installs the result into the main `vendor/`. |
| CLT-only Ghostty build (#42) | `scripts/ghostty-build/`: the per-pin Ghostty build patch, precompiled `Ghostty.metallib` + provenance, and a README (why, pin bumps, removal). |
| Ghostty source | `~/git/ghostty`, the user's checkout, read-only. Since #85 the pin is the **v1.4.0 tag**, `83fb95624` (zig 0.17), which this checkout **doesn't contain** (it's at 822e84272, an ancestor whose `ghostty.h` lacks only `ghostty_surface_paste_text`). Reading the pin's source needs a `git clone --shared` + fetch in a scratch dir: a download, so ask first on metered wifi. |
| cmux source | `~/git/cmux` (reference for agent integration). Read-only; branch switching allowed only with a clean tree, restored afterwards. |

## Merging and verifying

- Agents merge only through `.git/coord/merge.sh "<summary>"`: lock → rebase → `swift build` →
  `DEALER_SELFTEST=quit .build/debug/Dealer` → **step-count guard** (refuses if `SELFTEST PASS N`
  drops below `last-pass-count`) → fast-forward master → log.
- **merge.sh's run is the verification; one full run per merge is the gate (#47).** The lead
  pushes **the SHA merge.sh verified** (`git push origin $SHA:master`, the SHA in its BOARD.md
  line) without rerunning the self-test. Before #47 the lead reran every merge, and agents did 5
  to 30 full runs per issue; at ~3.5 min a run that was most of the time spent. Never push a
  SHA merge.sh didn't log, and never a later master tip "because it includes it": agents keep
  merging, and a `| tail` pipe hides a failing exit code (both mistakes happened once).
- Agents iterate with `DEALER_SELFTEST_ONLY=<title prefix>` on the sections they touch and leave
  the full run to merge.sh. A refused merge (a red step) costs one more full run, so tell agents
  to rerun only the failing sections before retrying.
- Self-test steps wait on their own conditions (`SelfTest.waitUntil`), never on fixed delays,
  and there is no pause between steps (`DEALER_SELFTEST_DELAY` defaults to 0). A full run takes
  about 20 s. Reject a new step that sleeps a fixed time or passes only at a nonzero delay.
- **Fetch before pushing.** The user sometimes edits on GitHub (README) and another of their
  sessions sometimes commits straight to master (#64, the toolchain pin). If origin moved, rebase
  local master onto it, rerun the self-test under the lock, then push. After a direct commit,
  reset `last-pass-count` to a fresh baseline.
- **The lead may run merge.sh itself** from an agent's worktree when the agent is done but the
  gate was blocked (e.g. a locked screen), and may commit an agent's uncommitted work as WIP after
  a usage-limit cutoff, before resuming it.
- The user has authorized **pushing master after a verified landing**, and pushing the `media`
  branch for demos after a full privacy review. They're sometimes on **metered wifi**: then no downloads (Ghostty
  fetches, demo media), and agents are told so; small code pushes are fine. Ask first for anything else outward:
  releases, deleting remote branches, repo settings.
- The self-test drives a real window. **A locked screen** turns shell/drag steps into skips or
  failures; agents must wait rather than merge around it.
- **Known intermittent failure block** (sidebar drops, pill clicks/reorder, row clicks,
  `colors: … render identically`, titlebar tabs, edge split): caused by a **sleeping display**
  under a locked screen (#38). The runner now prints `SELFTEST NOTE: display asleep…` and
  `(environment: …)` next to failures; such a run proves nothing about click/drag steps. Wait for
  the user's screen, or `caffeinate -u -t 600 &` wakes the display (still locked: shell steps
  skip, clicks pass). Modal confirmations can no longer cause it: self-test mode auto-accepts them
  and the runner fails any step that leaves a sheet open. Never use `ALLOW_FEWER_TESTS` for this.
- Things the self-test can't prove, which need the user's real hands (put them in `TODO.md`):
  - real pointer drags and titlebar behavior (window server decides);
  - real key presses;
  - macOS notifications and their icon (bundle + Notification Center cache);
  - the look of anything under the user's own theme.
- Agents can't post input events to other apps (no Accessibility permission), but have Screen
  Recording permission.

## Agent roster (by expertise; IDs are per-session)

Route follow-ups to whoever has the context:
- **workspaces**: built workspaces, sidebar, switcher modes, settings.toml, colors, tabs-in-titlebar
  (#1, #6, #8, #9, #10, #15, #16, #18). *The user stopped this agent once (after #16); don't reuse
  it silently.*
- **visuals**: Theme, chrome styling, pane close × and middle-click, theming research, demo
  recordings (DemoMouse, record-demo.sh), titlebar click routing and drag zones (#2, #23, #24, #26,
  #27, #28, #36, #37).
- **attention**: attention model, rings/outlines, red failed state, fade-out, Claude Code research
  and the bundled plugin, cmux research, env scrubbing (#4, #7, #12, #29, #34).
- **cli**: control socket, `dealer` CLI, `dealer run` / `b` (#5, #21, #32).
- **icon**: app icon, bundle.sh, Launch Services / Notification Center (#22, #30).
- **edge-split**: controller layout/promote sizing (#31), live ghostty config reload + chrome
  re-theming via `Theme.didChange` (#33).
- **rename**: the Dealer rename, build scripts, the Ghostty pin and its enforcement
  (`check-ghostty.sh`, launch banner) (#3, #20, #35).
- **selftest-env**: Ghostty resource lookup and pinned shell integration for the self-test,
  `Confirmation.skip` plus the per-step modal guard, and the sleeping-display finding (#38, #39, #40).
- **memory**: leak audit, `LiveObjects` counts, SelfTestMemory, `dealer diagnose` / Help › Capture
  Memory Diagnostics, the self-test freeing closed panes' terminals (#43).
- **run-tab**: out-of-view panes get their real size, so background output survives (#45).
- **cmd-n**: menu shortcuts (⌘N workspace, ⇧⌘N window) and `SelfTestShortcuts` (#44).
- **tab-fit**: tabs sized to their titles, capped by `Theme.Metrics.tabMaxWidth` (#46).
- **waits**: `SelfTest.waitUntil`, the timer-driven runner without a step delay (#47).

Session of 2026-10-11..16 (these IDs are gone; the names are what to brief by):
- **memory2**: Ghostty pin bump to b1d9492 (#43: hidden panes free GPU memory, `GhosttyClipboard`
  MIME port, no-setenv-after-init rule), window occlusion (#54), `dealer close tab` (#60), Go to
  Pane ⌘⇧A (#66), clipboard asks (#55) and paste protection (#72).
- **ws-select**: selected-workspace look (#52), titlebar deck accent (#59), sidebar leaf name
  (#68), waiting `?` glyph (#65), demo re-recording.
- **notify-log**: notification decision log (#56), wrong comments (#58), done outline + `[attention]`
  (#61), `dealer run` linger (#63), flaky hooks step (#62), presence rules (#71).
- **caffeine**: `[power] caffeinate` + titlebar cup (#69). **blur**: transparency/blur/glass (#67),
  self-test ignoring the user's opacity. **bundle-warn**: zero-warning build, codesign failures (#70).

Session of 2026-10-28..29:
- **ghostty-bump**: pin to the v1.4.0 tag (#85), tag version string for the pin check, zig 0.17.
- **tab-underline**: active-tab deck underline on connected tabs and with one deck (#86).
- **tab-contrast**: chrome shade, `[colors] chrome_contrast` (a signed dial since chrome-signed), hover ordering,
  `TabStyle.translucent` options (#87).

## The user's preferences (learned)

- **Merge early**, small increments. Fan out in parallel; keep the user informed concisely.
- They sometimes say **"don't pick up new issues"** or **"don't assign an agent yet"**. Then file
  issues only and leave them unassigned, until told otherwise.
- **Push back on complexity.** For fiddly platform work (#27), research first and report the
  simplest option before building heavy machinery.
- **Research then decide:** they like findings posted on the issue (Ghostty/cmux deep-dives).
- Hands-on tester: reports results in `TODO.md`. Turn each note into an action (issue, reopen,
  relay) and annotate it with ✅/🔄, without rewriting their text. **A hand check marked `[x]`
  means checked and good:** close its issue and remove the item.
- For big visual features they may ask to **review the diff before it lands** (#67): then the
  agent doesn't run merge.sh; show `git diff master...<branch>` and merge on approval.
- Code audits: they want **only clear-value, low-risk fixes** (#57); keep `#NN` tags in code.
- **Vocabulary:** pane, deck, tab, workspace, promote, fold, "pane bar" (not "pane titlebar").
- **Product decisions on record** (details in CLAUDE.md "Behavior decisions"):
  - a workspace color shows only on its switcher entry; it never affects tabs;
  - mouse-first demos, regenerated by script;
  - `dealer run` routes by pane cwd: no workspace root directories, no `--wait`;
  - one-arg/many-arg quoting, `b() { dealer run -- "$@"; }`;
  - failed > waiting > done > unread; failed is red; Claude API errors and failed commands go red;
  - *done* draws the same blue outline as *waiting* by default (#61, `[attention] done`); the
    waiting dot carries a `?` (#65);
  - no desktop banner while Dealer is the active app; a locked screen counts as away (#71);
  - clipboard follows ghostty: reads and unsafe pastes ask (#55, #72);
  - #23 (theme-derived accent colors) is *not planned*; #33 (live config reload) is wanted;
  - README demos are recorded with **pill** tabs (`Demo.tabStyle`), though connected is the default;
  - the active tab's deck underline shows with any number of decks (#86);
  - tab/chrome contrast: tunable as a signed dial, `[colors] chrome_contrast` −1…+1, default −0.3
    (#87; it replaced a WCAG target of 1.35 whose darken-to-lighten flip at 1.38 confused them).
- They don't want outward surprises. They're fine with secrets-free GitHub comments and issue
  creation on their behalf.

## The user's environment (relevant facts)

- They run the bundled app (`scripts/bundle.sh && open build/Dealer.app`). It must be launched with
  `open`, not from a cmux shell (inherited `CMUX_*` broke Claude hooks in #12; scrubbed now).
- Ghostty theme changes often (Frappé, GitHub Light Default, Nord; on 10-29 Kanso Mist with
  `background-opacity = 0.5` + `macos-glass-regular`). The self-test loads their real ghostty
  config (opacity/blur are ignored there since 8e7cb58), so a theme change can surface in pixel
  steps. Shell: zsh with direnv, oh-my-posh and atuin. They **no longer** run Claude with
  `--dangerously-skip-permissions`.
- This orchestrator and its agents run **inside Dealer** (`build/Dealer.app`, ad-hoc signed).
  Screen capture needs Dealer to have Screen Recording permission, and a `bundle.sh` rebuild can
  drop it (new signature). Agents must never run bundle.sh in the main checkout (it replaces the
  running app).
- `~/.zshenv` exports a Claude OAuth token: **never grep or print it** (leaked twice; rotated).
- Screen Recording: Dealer sessions lack it; launch `record-demo.sh` (or any capture) through
  `open -na /Applications/Ghostty.app --args -e <script>`.
- Sometimes on **metered wifi**: then no large downloads/uploads (dep fetches, clones, media); small
  `gh` calls and code pushes are OK when they say so. Ask if unsure.
- Pushing the `media` branch is blocked by the auto-mode classifier; the user pushes it themselves.
  Video uploads for the README: `gh issue comment N -R jonsmithers/dealer --attach <file>.mp4` (user).

## Incidents to not repeat

| Incident | Guard now in place |
|---|---|
| Agent printed the OAuth token (env grep, then rc-file grep) | Briefs: grep names only, never values |
| `/tmp` cleanup deleted merge.sh, then the whole board | Coord lives in `.git/coord` |
| Squash onto moved master silently reverted #31 | Merge-base squash rule + step-count guard |
| Assigned an issue the user had already closed (#11) | Re-check issue state before assigning |
| Over-literal reading removed pill colors (#15 → bug #18) | Flag adjacent consequences of literal readings |
| `gh issue create` made empty issues twice | Write body files first; `--body-file <file>` |
| Demo recorder captured the desktop after the window closed | Recorder stops on `DEMO DONE` before exit; review contact sheets |
| `toggleSidebar(_:)` collided with NSWindow's selector (#13) | Don't name menu actions after AppKit selectors (CLAUDE.md) |
| Pushed after a red self-test (`| tail` swallowed the exit code) | Capture output, check `$?`, then push |
| Pushed a commit merged mid-test (untested by the lead) | Push the recorded `$SHA:master` |
| Agents cut off by rate limits / API overload / network loss (many times) | Inspect the worktree, commit WIP, resume with "you were at X" |
| Overnight lock: the display slept and the self-test failed about 21 steps then crashed (#38) | Treat runs while the display is asleep or the screen is locked as not verified; the runner prints a `SELFTEST NOTE` |
| zsh `"$P:src/…"` applied the `:s` modifier in a `git show` | Write `"${P}:path"` |
| Self-test instances left running by interrupted agents grew to ~6 GB each; the user killed them | Runner frees closed panes' terminals (~600 MB per run); agents kill every Dealer they start, by PID, before stopping |
| A fixed 0.6 s pause per step hid races and made runs ~3.5 min; agents reran the full suite 5–30× per issue | Condition waits (`waitUntil`), ~20 s runs, one full run per merge in merge.sh; the lead pushes what merge.sh verified (#47) |
| "See it running" command used `DEALER_SELFTEST=1 DEALER_SELFTEST_DELAY=2`: the whole suite at 2 s/step (~13 min) | To just look, `DEALER_SELFTEST_ONLY=none`; a window started from a terminal opens behind the front window |
| The user's translucent ghostty config made pixel steps fail on master (#67 follow-up) | `Transparency.ignoresConfig` in self-test mode; `PixelProbe.matches` compares alpha |
| Usage limits cut agents off before they committed (twice in a row) | Lead commits their worktree as WIP, then resumes them |
| Teammate panes looked stuck: a teammate sees messages (the lead's or the user's) only between turns | Check its transcript/commits before calling it stuck; Esc in its pane delivers a queued message; replace it with a fresh agent briefed from its last commit |

## State at hand-off (2026-10-29)

- **Master: #87 plus its doc follow-up, 507 self-test steps (~57 s per merge.sh run), pushed.** `media` is at
  `f71c6a4` (pill-tab demos, 10-29); README video URLs point at the #86 comment uploads.
- **Open, waiting for the user's hand checks (in `TODO.md`):** #85 (Ghostty v1.4.0: IME, sleep/wake,
  look, no banner, shell integration), #86 (underline look + grip-dots decision), #87 (contrast
  under real glass, real hover, `chrome_contrast` by hand).
- **Watch:** `memory: a pane created out of view draws at its real size when first shown`
  ("shown pane is still occluded") flakes ~40% on old and new frameworks; a candidate for its own
  issue. One merge.sh run failed 3 unnamed steps on a README-only change (10-29), retry passed.
- The previous vendor builds are kept in `.git/coord/vendor-old-*`.
- No agents running. Worktrees: `myterm-wt/media-branch` only.
- Generic skill: `~/git/orchestrate-issues` (GitHub `jonsmithers/orchestrate-issues`, private),
  symlinked as `~/.claude/skills/orchestrate-issues`. Add generic lessons there and Dealer-specific
  ones here.
