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
| Ghostty source | `~/git/ghostty`, the user's checkout. Read-only `git show <pin>:<path>` only; it's ahead of the pin in `scripts/ghostty.version`. |
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
- The user has authorized **pushing master after a verified landing**, and pushing the `media`
  branch for demos after a full privacy review. Ask whether they're on **metered wifi** before
  pushing media; they asked to hold video pushes once. Ask first for anything else outward:
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

## The user's preferences (learned)

- **Merge early**, small increments. Fan out in parallel; keep the user informed concisely.
- They sometimes say **"don't pick up new issues"** or **"don't assign an agent yet"**. Then file
  issues only and leave them unassigned, until told otherwise.
- **Push back on complexity.** For fiddly platform work (#27), research first and report the
  simplest option before building heavy machinery.
- **Research then decide:** they like findings posted on the issue (Ghostty/cmux deep-dives).
- Hands-on tester: reports results in `TODO.md`. Turn each note into an action (issue, reopen,
  relay) and annotate it with ✅/🔄, without rewriting their text.
- **Vocabulary:** pane, deck, tab, workspace, promote, fold, "pane bar" (not "pane titlebar").
- **Product decisions on record** (details in CLAUDE.md "Behavior decisions"):
  - a workspace color shows only on its switcher entry; it never affects tabs;
  - mouse-first demos, regenerated by script;
  - `dealer run` routes by pane cwd: no workspace root directories, no `--wait`;
  - one-arg/many-arg quoting, `b() { dealer run -- "$@"; }`;
  - failed > waiting > done > unread; failed is red; Claude API errors and failed commands go red;
  - #23 (theme-derived accent colors) is *not planned*; #33 (live config reload) is wanted.
- They don't want outward surprises. They're fine with secrets-free GitHub comments and issue
  creation on their behalf.

## The user's environment (relevant facts)

- They run the bundled app (`scripts/bundle.sh && open build/Dealer.app`). It must be launched with
  `open`, not from a cmux shell (inherited `CMUX_*` broke Claude hooks in #12; scrubbed now).
- Ghostty theme: Catppuccin Frappé. Shell: zsh with direnv, oh-my-posh and atuin; `cc` runs
  Claude with `--dangerously-skip-permissions`, so it never shows *waiting* from permission
  prompts.
- `~/.zshenv` exports a Claude OAuth token: **never grep or print it** (leaked twice; rotated).

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
| Teammate panes looked stuck: a teammate sees messages (the lead's or the user's) only between turns | Check its transcript/commits before calling it stuck; Esc in its pane delivers a queued message; replace it with a fresh agent briefed from its last commit |

## State at hand-off (2026-10-08, end of round 8)

- **Master `70a1f1d`, 279 self-test steps (~20 s per run), pushed.** `media` is at `8a3762b`.
- **Landed, open for the user's checks (in `TODO.md`):** #41 (bundled Ghostty resources), #44 (⌘N
  New Workspace, ⇧⌘N New Window), #45 (`dealer run --tab` output survives), #27 (titlebar drag zones).
- **#43 (memory):** two leaks fixed (356c9b2), diagnostics added. ~65–70 MB per pane is libghostty's
  renderer (the user confirmed Ghostty.app is similar). Open in case memory grows with few panes.
- **#42 (no Xcode):** landed 4c22f5a; open until the reporter confirms on a Mac with only the CLT.
- **#46 (tab-fit experiment):** branch `issue-46-tab-fit` (a13c1eb, pushed), bundle in
  `myterm-wt/tab-fit/build/Dealer.app`. **Don't merge until the user approves.**
- **#47:** landed 70a1f1d; open for the user. `.git/coord/merge.sh` gained a 300 s timeout, a
  refusal on `SELFTEST NOTE`/`(skipped`, failing-step output and run time on the board line
  (backup `merge.sh.bak-0108`). A one-line `|| true` fix on its failure grep is pending the user's OK.
- **Possible bug, not filed:** Split Down's ⇧⌘D uses `"d"` + shift, the pattern that broke ⇧⌘N
  (cmd-n's finding); the user was asked to try a real ⇧⌘D.
- No agents running. Worktrees: `myterm-wt/media-branch`, `myterm-wt/tab-fit`.
- Generic skill: `~/git/orchestrate-issues` (GitHub `jonsmithers/orchestrate-issues`, private),
  symlinked as `~/.claude/skills/orchestrate-issues`. Add generic lessons there and Dealer-specific
  ones here.
