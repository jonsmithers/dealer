# media (orphan branch)

This branch holds only binary media for the Dealer README, so recordings never bloat `master`'s
history. It shares no history with `master`; don't merge it.

- `demos/*.gif`: inline in the README (GitHub renders GIFs from raw URLs).
- `demos/*.mp4`: higher-quality versions, linked next to each GIF.

Recorded with `scripts/record-demo.sh` on `master` (scripted demo mode, `DEALER_DEMO=<name>`),
in a neutral `/tmp/demo` project with a neutral prompt. To update: rerun the script, review every
frame, copy the files here, and commit to this branch only.
