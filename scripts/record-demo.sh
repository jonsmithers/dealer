#!/bin/zsh
# Regenerates the README demo recordings (#26, #28): scripted mouse demos (Sources/Dealer/Demo.swift),
# recorded, encoded to GIF + MP4, size-checked, with contact sheets for the privacy review.
#
#   scripts/record-demo.sh <out-dir> [demo…]                       # record (default: all demos)
#   scripts/record-demo.sh <out-dir> --publish <media-worktree>    # copy reviewed files to `media`
#
# Recording needs an unlocked screen and Screen Recording permission for the app running this
# script (Terminal, Ghostty, …). It runs `.build/debug/Dealer`, so `swift build` first. The demo
# window floats over everything while it records; don't use the machine meanwhile.
#
# Publishing is never implicit: --publish only copies the GIFs/MP4s from <out-dir> into
# <media-worktree>/demos (a worktree of the orphan `media` branch), removes demos that are no longer
# produced, commits there, and prints the push command. Review <out-dir>/review/*.png first.
set -e; setopt pipefail
ROOT=${0:A:h:h}; OUT=${1:?usage: record-demo.sh <out-dir> [demo…] | <out-dir> --publish <media-worktree>}; shift
ALL=(drag tabs workspaces attention)
GIF_BUDGET=$((5 * 1024 * 1024))
mkdir -p $OUT
OUT=${OUT:A}

if [[ $1 == --publish ]]; then
  WT=${2:?--publish needs the media worktree path}
  [[ $(git -C $WT rev-parse --abbrev-ref HEAD) == media ]] || { print "$WT is not on the media branch"; exit 1; }
  mkdir -p $WT/demos
  for f in $WT/demos/*(N); do
    name=${f:t}; [[ ${ALL[(Ie)${name:r}]} -gt 0 ]] || git -C $WT rm -q "demos/$name"
  done
  for d in $ALL; do
    [[ -f $OUT/$d.gif && -f $OUT/$d.mp4 ]] || { print "missing $OUT/$d.gif or .mp4; record all demos first"; exit 1; }
    cp $OUT/$d.gif $OUT/$d.mp4 $WT/demos/
  done
  git -C $WT add -A demos
  git -C $WT commit -qm "Regenerate demo recordings (scripts/record-demo.sh)" || { print "nothing changed"; exit 0; }
  git -C $WT log --oneline -1
  print "Committed on media. After reviewing $OUT/review, publish with:\n  git -C $WT push origin media"
  exit 0
fi

DEMOS=($@); (( $#DEMOS )) || DEMOS=($ALL)
BIN=$ROOT/.build/debug/Dealer
[[ -x $BIN ]] || { print "build first: swift build"; exit 1; }
DEMO_DIR=/tmp/demo

# A neutral project and shell: no personal paths, prompt or history on screen.
rm -rf $DEMO_DIR; mkdir -p $DEMO_DIR/src $DEMO_DIR/tests; cd $DEMO_DIR
print -r -- "PS1='%F{blue}%1~%f %F{magenta}\$%f '" > .zshrc
print -r -- "alias dealer='\"\$DEALER_CLI\"'" >> .zshrc
print -r -- "HISTFILE=/dev/null" >> .zshrc
# Ghostty's shell integration, so Dealer knows when a pane is idle (no "process running" prompts).
print -r -- '[[ -n $GHOSTTY_RESOURCES_DIR ]] && source "$GHOSTTY_RESOURCES_DIR"/shell-integration/zsh/ghostty-integration' >> .zshrc
: > .zshenv
print -r -- ".zsh*" > .gitignore
printf 'test:\n\t@echo "  ok  42 passed (1.3s)"\n' > Makefile
printf '# demo app\n' > README.md
printf '12:00:01 GET /health 200\n12:00:02 GET /api/items 200\n12:00:04 POST /api/items 201\n' > server.log
G=(git -c user.name=demo -c user.email=demo@example.com)
git init -q -b main
$G add Makefile README.md .gitignore && $G commit -qm "Initial project"
$G add server.log && $G commit -qm "Add request log"
touch src/app.js tests/app.test.js && $G add src tests && $G commit -qm "Add items API and tests"
cd $ROOT

# Bounds (points, top-left origin) of our own Dealer window, by PID, plus the display scale.
BOUNDS=$OUT/.bounds
[[ -x $BOUNDS ]] || { print -r -- 'import CoreGraphics
let pid = Int(CommandLine.arguments[1])!
for w in CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as! [[String: Any]]
where (w[kCGWindowOwnerPID as String] as? Int) == pid && (w[kCGWindowLayer as String] as? Int ?? -1) >= 0 {
  // The demo window floats (layer > 0); skip small helper windows.
  let b = w[kCGWindowBounds as String] as! [String: Double]
  guard b["Width"]! > 300 else { continue }
  let d = CGMainDisplayID(), scale = CGDisplayCopyDisplayMode(d)!.pixelWidth / Int(CGDisplayBounds(d).width)
  print(Int(b["X"]!), Int(b["Y"]!), Int(b["Width"]!), Int(b["Height"]!), scale); break }' > $OUT/.bounds.swift && swiftc -O $OUT/.bounds.swift -o $BOUNDS; }

# Record the screen region under the window with ffmpeg/avfoundation: unlike `screencapture -v -l`,
# it leaves out the real pointer (the demo draws its own), and macOS doesn't swap the traffic
# lights for a capture badge. The demo floats its window above everything, so the region shows
# only Dealer.
SCREEN=$( (ffmpeg -f avfoundation -list_devices true -i "" 2>&1 || true) | sed -n 's/.*\[\([0-9]*\)\] Capture screen 0.*/\1/p')
mkdir -p $OUT/review

for demo in $DEMOS; do
  rm -f $OUT/$demo-raw.mp4 $OUT/review/$demo-*.png(N)
  DEALER_SELFTEST=1 DEALER_DEMO=$demo DEALER_DEMO_DIR=$DEMO_DIR $BIN > $OUT/$demo.log 2>&1 &
  PID=$!
  trap 'kill $PID 2>/dev/null' EXIT
  sleep 1.5
  B=($($BOUNDS $PID)); SCALE=${B[5]}
  (( $#B == 5 )) || { print "no Dealer window found"; exit 1; }
  CROP="$((B[3]*SCALE)):$((B[4]*SCALE)):$((B[1]*SCALE)):$((B[2]*SCALE))"
  ffmpeg -v error -y -f avfoundation -pixel_format bgr0 -capture_cursor 0 -framerate 30 -t 90 -i "$SCREEN:none" \
    -vf "crop=$CROP" -c:v libx264 -crf 16 -pix_fmt yuv420p $OUT/$demo-raw.mp4 2>/dev/null &
  FF=$!
  # Stop recording when the demo says it's done, while its window is still up: frames after the
  # window closes would show the user's screen. Only then does the app exit.
  until grep -q "DEMO DONE" $OUT/$demo.log 2>/dev/null || ! kill -0 $PID 2>/dev/null; do sleep 0.1; done
  kill -INT $FF; wait $FF || true
  grep -q "DEMO DONE" $OUT/$demo.log || { print "$demo exited without finishing; discarding"; rm -f $OUT/$demo-raw.mp4; exit 1; }
  while kill -0 $PID 2>/dev/null; do sleep 0.2; done

  # Drop the first second (shells starting). GIF: two-pass palette, 25 fps, 960px wide. MP4: the
  # full-resolution "full quality" link. Metadata is stripped from both.
  F="trim=start=1,setpts=PTS-STARTPTS,fps=25,scale=960:-1:flags=lanczos"
  ffmpeg -v error -y -i $OUT/$demo-raw.mp4 -vf "$F,palettegen=stats_mode=diff:max_colors=128" $OUT/$demo-palette.png
  ffmpeg -v error -y -i $OUT/$demo-raw.mp4 -i $OUT/$demo-palette.png -lavfi "${F}[x];[x][1:v]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle" -map_metadata -1 $OUT/$demo.gif
  ffmpeg -v error -y -ss 1 -i $OUT/$demo-raw.mp4 -c:v libx264 -crf 26 -preset slow -pix_fmt yuv420p -movflags +faststart -map_metadata -1 -an $OUT/$demo.mp4
  SIZE=$(stat -f %z $OUT/$demo.gif)
  (( SIZE <= GIF_BUDGET )) || { print "$demo.gif is $SIZE bytes, over the 5 MB budget"; exit 1; }

  # Privacy review: every frame of the GIF, 4 per second, tiled; read all of them before publishing.
  ffmpeg -v error -y -i $OUT/$demo.gif -vf "fps=4,scale=480:-1,tile=4x6" $OUT/review/$demo-%02d.png
  printf '%-11s gif %5d KB  mp4 %5d KB  %ss  review: %s\n' $demo $((SIZE / 1024)) $(( $(stat -f %z $OUT/$demo.mp4) / 1024 )) \
    $(ffprobe -v error -show_entries format=duration -of csv=p=0 $OUT/$demo.mp4 | cut -c1-4) "$OUT/review/$demo-*.png"
done
