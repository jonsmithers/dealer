#!/bin/zsh
# Records the README demo GIFs (#26). Usage: scripts/record-demo.sh <out-dir> [panes workspaces attention]
# Needs an unlocked screen and Screen Recording permission for the app running this script.
# The GIFs belong on the orphan `media` branch, never on master.
set -e; setopt pipefail
ROOT=${0:A:h:h}; OUT=${1:?out dir}; shift
DEMOS=($@); (( $#DEMOS )) || DEMOS=(panes workspaces attention)
BIN=$ROOT/.build/debug/Dealer
DEMO_DIR=/tmp/demo
mkdir -p $OUT

# A neutral project and shell: no personal paths, prompt or history on screen.
rm -rf $DEMO_DIR; mkdir -p $DEMO_DIR/src $DEMO_DIR/tests; cd $DEMO_DIR
print -r -- "PS1='%F{blue}%1~%f %F{magenta}\$%f '" > .zshrc
print -r -- "alias dealer='\"\$DEALER_CLI\"'" >> .zshrc
print -r -- "HISTFILE=/dev/null" >> .zshrc
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
# it can leave out the pointer, and macOS doesn't swap the traffic lights for a capture badge.
# The demo floats its window above everything, so the region shows only Dealer.
SCREEN=$( (ffmpeg -f avfoundation -list_devices true -i "" 2>&1 || true) | sed -n 's/.*\[\([0-9]*\)\] Capture screen 0.*/\1/p')

typeset -A LEN; LEN=(panes 21 workspaces 18 attention 16)
for demo in $DEMOS; do
  DEALER_SELFTEST=1 DEALER_DEMO=$demo DEALER_DEMO_DIR=$DEMO_DIR $BIN > $OUT/$demo.log 2>&1 &
  PID=$!
  trap 'kill $PID 2>/dev/null' EXIT
  sleep 1.5
  B=($($BOUNDS $PID)); SCALE=${B[5]}
  (( $#B == 5 )) || { print "no Dealer window found"; exit 1; }
  CROP="$((B[3]*SCALE)):$((B[4]*SCALE)):$((B[1]*SCALE)):$((B[2]*SCALE))"
  ffmpeg -v error -y -f avfoundation -pixel_format bgr0 -capture_cursor 0 -framerate 30 -t ${LEN[$demo]:-20} -i "$SCREEN:none" \
    -vf "crop=$CROP" -c:v libx264 -crf 16 -pix_fmt yuv420p $OUT/$demo-raw.mp4 2>/dev/null
  kill $PID
  # Two-pass palette GIF at 10 fps, 1000px wide; and a smaller MP4 for the "full quality" link.
  F="fps=10,scale=1000:-1:flags=lanczos"
  ffmpeg -v error -y -i $OUT/$demo-raw.mp4 -vf "$F,palettegen=stats_mode=diff" $OUT/$demo-palette.png
  ffmpeg -v error -y -i $OUT/$demo-raw.mp4 -i $OUT/$demo-palette.png -lavfi "${F}[x];[x][1:v]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle" $OUT/$demo.gif
  ffmpeg -v error -y -i $OUT/$demo-raw.mp4 -c:v libx264 -crf 26 -preset slow -pix_fmt yuv420p -movflags +faststart -an $OUT/$demo.mp4
  ls -la $OUT/$demo.gif $OUT/$demo.mp4
done
