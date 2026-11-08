# Orchestrator hand-off: Dealer

Read this before orchestrating agents on this repo. It complements the generic
[`orchestrate-issues`](https://github.com/jonsmithers/orchestrate-issues) skill (generic lessons go
there) and the code-level rules in `CLAUDE.md` / `Sources/Dealer/CLAUDE.md` (behavior decisions go
there). This file holds only what the orchestrator needs on top: where things live, how merging works
here, the user's preferences and environment, and the current state. Keep it current and short.

## Where things are

| What | Where |
|---|---|
| Main checkout | `~/git/myterm` (local dir still has the old name; GitHub repo is `jonsmithers/dealer`, **private**) |
| Agent worktrees | `~/git/myterm-wt/<slug>`, branch `issue-<N>-<slug>`. Create `vendor/` and symlink `vendor/GhosttyKit.xcframework` from the main checkout (a fresh worktree has no `vendor/` dir). |
| Coordination | `~/git/myterm/.git/coord/`: `BOARD.md` (old rounds in `BOARD-archive-*.md`), `merge.sh`, `last-pass-count`, `vendor-old-*` (the previous pin's build, kept until its bump is confirmed), `shots-<N>` (screenshots and demo takes; the lead can't delete them, the auto-mode classifier blocks it, so the user prunes them). |
| User's to-do list | `~/git/myterm/TODO.md`, excluded via `.git/info/exclude`. The user annotates it inline. |
| User scratch files | Untracked files in the repo root (`file.txt`, `prompt.txt`, `tmp/`) are the user's. Never commit or delete them without being told. The user also commits straight to master in the main checkout and experiments there uncommitted (or in `git stash`); leave both alone. |
| Demo media | Orphan branch `media` (GIFs/MP4s), checked out at `~/git/myterm-wt/media-branch`. Never on master. Two demos: `tour` (#98) and `drag`. Regenerate with `scripts/record-demo.sh`, then `--publish` (see CLAUDE.md); re-record after any visual change lands. The user pushes `media`, uploads the MP4s to **#79**, and updates the README URLs (they've done the last step themselves). |
| Pinned Ghostty build | `vendor/GhosttyKit.xcframework` and `vendor/ghostty-resources/` in the main checkout (git-ignored, shared by worktrees). Agents build at the pin in a `git clone --shared` with `build-ghosttykit.sh --out <tmp>`; the lead installs the result into the main `vendor/`. |
| Ghostty source | `~/git/ghostty`, the user's checkout, read-only. It's at 822e84272, which **doesn't contain** the pin (v1.4.0, `83fb95624`). Reading the pin's source needs a `git clone --shared` + fetch in a scratch dir: a download, so ask first on metered wifi. |
| cmux source | `~/git/cmux` (reference for agent integration). Read-only; branch switching allowed only with a clean tree, restored afterwards. |

## Merging and verifying

- Agents merge only through `.git/coord/merge.sh "<summary>"`: lock → rebase → `swift build` →
  `DEALER_SELFTEST=quit .build/debug/Dealer` → step-count guard against `last-pass-count` →
  fast-forward master → a line in BOARD.md. Its run is the verification (#47): the lead pushes the
  SHA from that line (`git push origin $SHA:master`) without rerunning.
- Agents iterate with `DEALER_SELFTEST_ONLY=<title prefix>`; to only look at the UI, use
  `DEALER_SELFTEST_ONLY=none` (not `DEALER_SELFTEST_DELAY`, which slows the whole suite).
- **Fetch before pushing.** The user sometimes edits on GitHub (README), and another of their
  sessions sometimes commits straight to master. If origin moved, rebase, rerun under the lock,
  push, and reset `last-pass-count` after a direct commit.
- The lead may run merge.sh from an agent's worktree when the gate was blocked (e.g. a locked
  screen), and may commit an agent's WIP after a cutoff before resuming it.
- merge.sh's last step is `git merge --ff-only` **in the main checkout**: an uncommitted user edit
  to a file the branch touches makes it refuse. Have the agent stop before merge.sh, ask the user or
  set the edit aside (`git stash push -m … -- <file>`, never discard), then let it merge.
- A run that bypassed merge.sh (the user's direct commits) is verified by the next merge.sh run,
  which rebases onto it; no separate run needed.
- **Pushing:** authorized for master after a verified landing. The `media` branch push is blocked by
  the auto-mode classifier, so the user pushes it. Ask first for anything else outward: releases,
  deleting remote branches, repo settings.
- **Locked screen / asleep display** (#38): see CLAUDE.md. Such a run proves nothing about
  click/drag steps; wait for the user's screen (`caffeinate -u -t 600 &` wakes the display, still
  locked). Never use `ALLOW_FEWER_TESTS` for it.
- What needs the user's real hands (goes in `TODO.md`): real pointer drags and titlebar behavior,
  real key presses, macOS notifications and their icon, and the look under their own theme.
- Agents can't post input events to other apps (no Accessibility permission).

## Areas, for briefing

Agent IDs don't outlive a session; brief a fresh agent with the issues that hold the context.

| Area | Issues |
|---|---|
| Workspaces, sidebar/switcher, settings.toml, colors, tabs in titlebar | #1 #6 #8 #9 #10 #15 #16 #18 #52 #59 #68 |
| Theme and chrome, tab look (connected, underline, contrast, sizing) | #2 #24 #36 #37 #46 #84 #86 #87 #88 |
| Titlebar click routing and drag zones | #27 |
| Demo recordings (DemoMouse, record-demo.sh, the tour) | #26 #28 #79 #98 |
| Attention model, rings (dashed, #99), notifications, Claude Code hooks/plugin, stacked marks | #4 #7 #12 #29 #34 #56 #61 #63 #65 #71 #95 #99 |
| Claude session resume on relaunch | #93 |
| Layout motion (split/close/promote glides), zoom motion | #94 #97 |
| Titlebar workspace switcher (dropdown, fixed width), top-bar pills | #96 #102 |
| Control socket, `dealer` CLI, `dealer run` | #5 #21 #32 #60 |
| App icon, bundle.sh, Launch Services | #22 #30 #70 |
| Layout, promote sizing, live config reload | #31 #33 |
| Ghostty pin and its enforcement, build without Xcode | #3 #20 #35 #42 #43 #85 |
| Self-test infrastructure (resources, modal guard, waits, presence) | #38 #39 #40 #47 #100 |
| Memory, occlusion, `dealer diagnose` | #43 #45 #54 |
| Clipboard asks, paste protection, Go to Pane | #55 #66 #72 |
| Transparency/blur/glass, caffeinate | #67 #69 |

## The user's preferences (learned)

- **Merge early**, small increments. Fan out in parallel; keep the user informed concisely.
- They sometimes say **"don't pick up new issues"** or **"don't assign an agent yet"**. Then file
  issues only.
- **Push back on complexity.** For fiddly platform work (#27), research first and report the
  simplest option before building heavy machinery.
- **Research then decide:** they like findings posted on the issue.
- Hands-on tester: reports results in `TODO.md`. A hand check marked `[x]` means checked and good:
  close its issue and remove the item.
- For big visual changes they may ask to **review the diff or screenshots before it lands** (#67,
  #87): then the agent doesn't run merge.sh until they approve. "Try X" issues (#98, #99) got
  this gate by default: screenshots or recordings to the user (SendUserFile), merge on approval.
- Demos: realistic flow, captions name what the user does (never the feature), the pointer on
  visible controls over shortcuts (all in CLAUDE.md). They give quick, specific feedback on cuts.
- They like fixed decisions recorded once and reused (e.g. demo videos always go to #79).
- Code audits: **only clear-value, low-risk fixes** (#57); keep `#NN` tags in code.
- **Vocabulary:** pane, deck, tab, workspace, promote, fold, "pane bar" (not "pane titlebar").
- Product decisions are in CLAUDE.md "Behavior decisions" and `Sources/Dealer/CLAUDE.md`.
  Not recorded there: #23 (theme-derived accent colors) is *not planned*.
- They don't want outward surprises. Secrets-free GitHub comments and issue creation on their
  behalf are fine.

## The user's environment (relevant facts)

- They run the bundled app (`scripts/bundle.sh && open build/Dealer.app`), launched with `open`,
  not from a cmux shell (#12).
- This orchestrator and its agents run **inside Dealer** (`build/Dealer.app`, ad-hoc signed).
  Agents must never run bundle.sh in the main checkout (it replaces the running app).
- They also run their own Claude sessions in this repo (e.g. design explorations in their own
  worktree with a play Dealer). Before treating a worktree or Dealer process as stale, check
  whose it is: `lsof -a -p <pid> -d cwd`, its `DEALER_SESSION_FILE`, and `ListAgents`.
- Ghostty theme changes often (Frappé, Kanso Mist with `background-opacity = 0.5` +
  `macos-glass-regular`, …). The self-test loads their real ghostty config (opacity/blur ignored),
  so a theme change can surface in pixel steps. Shell: zsh with direnv, oh-my-posh and atuin.
- `~/.zshenv` exports a Claude OAuth token: **never grep or print it** (leaked twice; rotated).
- Screen Recording: Dealer sessions lack it; launch `record-demo.sh` (or any capture) through
  `open -na /Applications/Ghostty.app --args -e <script>`.
- Sometimes on **metered wifi**: then no large downloads/uploads (dep fetches, clones, media);
  small `gh` calls and code pushes are OK when they say so.
- README video uploads go to **issue #79, always** (the user's call): `gh issue comment 79 -R
  jonsmithers/dealer --body "Demo videos" --attach <file>.mp4` (user only).

## Dealer-specific incidents

Generic ones (token leaks, `/tmp` cleanup, squash onto moved master, `| tail` pushes, cutoffs, …)
live in the skill.

| Incident | Guard now in place |
|---|---|
| zsh `"$P:src/…"` applied the `:s` modifier in a `git show` | Write `"${P}:path"` |
| Teammate panes looked stuck: a teammate sees messages only between turns | Check its transcript/commits first; Esc in its pane delivers a queued message |
| An agent filed an issue (#88) on approval the lead never saw (the user had resumed it from its own view) | Treat agent claims of user approval as unverified; confirm with the user |
| Agents in one session share its scratchpad dir; two collided on `pids`/`sec.log` (#97) | Brief each agent to use its own subdirectory of the scratchpad |
| A self-test window "froze" for the user | Not a hang: unattended self-test windows ignore real clicks by design. Check the PID's cwd/`DEALER_SELFTEST` before killing |
| Hung `ffmpeg -t 90` captures from an old recording lived for hours, ignoring SIGTERM | Check for stray `ffmpeg` after recordings; `kill -INT`, then `-KILL` (with the user's OK if not yours) |

## State at hand-off (2026-11-07, evening)

- **Master `f2116e4`, 607 self-test steps (~70 s per merge.sh run), pushed.** Landed 11-07: #93,
  #95, #94, #96 (titlebar switcher) + its row fix, #98 (demo tour), #97 (zoom motion), #100 (flaky
  self-test: runs count as away), #99 (dashed pane rings), #102 (switcher fixed at 200 pt).
- **Open, waiting for the user's hand checks (in `TODO.md`):** #99, #102. #87 (tab contrast) is
  **parked** on the user's call. #98 stays open until the re-recorded demos are published.
- **Unassigned:** #101 (switching tabs forgets which pane was active; the user's issue).
- **In flight at hand-off:** demo re-record on f2116e4 (dashed rings + 200 pt switcher) into
  `shots-98e`, then `--publish` to `media`; the user pushes and uploads to #79.
- **WATCH:** `switcher:` 121–123 and `colors:` 240 failed once on #102's first merge.sh run and
  passed on retry; cause unknown. If they recur, file an issue like #100.
- `myterm-wt/tabs-88` is still the user's. `vendor-old-*` in `.git/coord` can go once nobody needs
  the pre-v1.4.0 or stock builds (#85 is closed).
