# media (orphan branch)

This branch holds only binary media for the Dealer README, so recordings never bloat `master`'s
history. It shares no history with `master`; don't merge it.

- `demos/*.gif`: inline in the README (GitHub renders GIFs from raw URLs).
- `demos/*.mp4`: higher-quality versions, linked next to each GIF.

Everything here is generated on `master` by `scripts/record-demo.sh` (scripted mouse demos in
`Sources/Dealer/Demo.swift`, in a neutral `/tmp/demo` project). To update: run it, read every
contact sheet it writes to `<out-dir>/review/`, then `scripts/record-demo.sh <out-dir> --publish
<this worktree>` and push this branch.
