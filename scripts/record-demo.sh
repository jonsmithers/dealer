#!/bin/zsh
# Regenerates the README demo recordings (#26, #28): scripted mouse demos (Sources/Dealer/Demo.swift),
# recorded, encoded to MP4 (the README's videos), size-checked, with contact sheets for the privacy
# review. No GIF: nobody used it. WebM (VP9) was measured instead and dropped too: at the MP4's
# quality it was only ~10% smaller and took ~20x as long to encode.
#
#   scripts/record-demo.sh <out-dir> [demo…]                       # record (default: all demos)
#   scripts/record-demo.sh <out-dir> --encode-only [demo…]         # re-encode <demo>-raw.mp4 takes
#   scripts/record-demo.sh <out-dir> --publish <media-worktree>    # copy reviewed files to `media`
#
# Recording needs an unlocked screen and Screen Recording permission for the app running this
# script (Terminal, Ghostty, …). It runs `.build/debug/Dealer`, so `swift build` first. The demo
# window floats over everything while it records; don't use the machine meanwhile.
#
# --encode-only redoes the MP4s and contact sheets from the raw captures already in <out-dir>
# (default: every demo that has one), without recording; it needs no screen access.
#
# Publishing is never implicit: --publish only copies the MP4s from <out-dir> into
# <media-worktree>/demos (a worktree of the orphan `media` branch), removes everything else there
# (old GIFs, demos that are no longer produced), commits there, and prints the push command.
# Review <out-dir>/review/*.png first.
set -e; setopt pipefail
ROOT=${0:A:h:h}; OUT=${1:?usage: record-demo.sh <out-dir> [demo…] | <out-dir> --encode-only [demo…] | <out-dir> --publish <media-worktree>}; shift
# Program status (OSC 7501, #89): working per demo, done when the contact sheets are ready to
# review, failed otherwise. A no-op outside a terminal; DEALER_PROGRAM_STATUS=0 turns it off.
source $ROOT/scripts/lib/program-status.sh
program_status_init dealer-demo record-demo
PID=
trap 'st=$?; [[ -n $PID ]] && kill $PID 2>/dev/null; program_status_exit $st' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
ALL=(tour drag)
VIDEO_BUDGET=$((5 * 1024 * 1024))  # per README video
mkdir -p $OUT
OUT=${OUT:A}

if [[ $1 == --publish ]]; then
  WT=${2:?--publish needs the media worktree path}
  [[ $(git -C $WT rev-parse --abbrev-ref HEAD) == media ]] || { print "$WT is not on the media branch"; exit 1; }
  mkdir -p $WT/demos
  for d in $ALL; do
    [[ -f $OUT/$d.mp4 ]] || { print "missing $OUT/$d.mp4; record (or --encode-only) all demos first"; exit 1; }
  done
  # Only the current demos' MP4s stay: old GIFs and dropped demos go.
  for f in $WT/demos/*(N); do
    name=${f:t}; [[ $name == *.mp4 && ${ALL[(Ie)${name:r}]} -gt 0 ]] || { git -C $WT rm -rqf --ignore-unmatch "demos/$name"; rm -rf $f; }
  done
  for d in $ALL; do cp $OUT/$d.mp4 $WT/demos/; done
  git -C $WT add -A demos
  git -C $WT commit -qm "Regenerate demo recordings (scripts/record-demo.sh)" || { print "nothing changed"; exit 0; }
  program_status done "Demos committed on media" "push with: git -C $WT push origin media"
  git --no-pager -C $WT log --oneline -1
  print "Committed on media. After reviewing $OUT/review, publish with:\n  git -C $WT push origin media"
  # README videos: always uploaded to issue #79 (CLAUDE.md, "README demo recordings").
  print "Then upload the MP4s (always to issue #79) and put each user-attachments URL in README.md:"
  print "  gh issue comment 79 -R jonsmithers/dealer --body 'Demo videos'${(j::)${(@f)$(for d in $ALL; do print -r -- " --attach ${(q)OUT}/$d.mp4"; done)}}"
  exit 0
fi

# encode DEMO: <out-dir>/DEMO-raw.mp4 → DEMO.mp4 (budget-checked) and review/DEMO-NN.png.
encode() {
  local demo=$1
  rm -f $OUT/review/$demo-*.png(N) $OUT/$demo.gif $OUT/$demo-palette.png  # GIF leftovers of older runs
  # Drop the first second (shells starting). Full resolution, x264 CRF 26: the terminal text stays
  # crisp, and it plays everywhere GitHub embeds it. Metadata is stripped.
  ffmpeg -v error -y -ss 1 -i $OUT/$demo-raw.mp4 -c:v libx264 -crf 26 -preset slow -pix_fmt yuv420p -movflags +faststart -map_metadata -1 -an $OUT/$demo.mp4
  local size=$(stat -f %z $OUT/$demo.mp4)
  (( size <= VIDEO_BUDGET )) || { print "$demo.mp4 is $size bytes, over the 5 MB budget"; exit 1; }
  # Privacy review: every frame of the published MP4, 4 per second, tiled; read all of them before publishing.
  ffmpeg -v error -y -i $OUT/$demo.mp4 -vf "fps=4,scale=480:-1,tile=4x6" $OUT/review/$demo-%02d.png
  printf '%-11s mp4 %5d KB  %ss  review: %s\n' $demo $((size / 1024)) \
    $(ffprobe -v error -show_entries format=duration -of csv=p=0 $OUT/$demo.mp4 | cut -c1-4) "$OUT/review/$demo-*.png"
}

if [[ $1 == --encode-only ]]; then
  shift
  DEMOS=($@)
  if (( ! $#DEMOS )); then  # by default, the demos that have a take
    for d in $ALL; do [[ -f $OUT/$d-raw.mp4 ]] || continue; DEMOS+=($d); done
  fi
  (( $#DEMOS )) || { print "no <demo>-raw.mp4 in $OUT"; exit 1; }
  mkdir -p $OUT/review
  for demo in $DEMOS; do
    [[ -f $OUT/$demo-raw.mp4 ]] || { print "missing $OUT/$demo-raw.mp4"; exit 1; }
    program_status working "Demos: encoding $demo" "MP4 and contact sheets" $(( 100 * (${DEMOS[(i)$demo]} - 1) / $#DEMOS ))
    encode $demo
  done
  program_status done "Demos encoded" "Review the contact sheets in $OUT/review before publishing"
  exit 0
fi

DEMOS=($@); (( $#DEMOS )) || DEMOS=($ALL)
BIN=$ROOT/.build/debug/Dealer
[[ -x $BIN ]] || { print "build first: swift build"; exit 1; }
DEMO_DIR=/tmp/demo
program_status working "Demos: setting up" "${(j:, :)DEMOS}"

# Neutral projects and shell: no personal paths, prompt or history on screen. The shell's files sit
# in $DEMO_DIR; each workspace of the tour has its project below it (api, web, docs), and the drag
# demo uses api.
rm -rf $DEMO_DIR; mkdir -p $DEMO_DIR/{api/{src,tests,.lib},web/src,docs}; cd $DEMO_DIR
print -r -- "PS1='%F{blue}%1~%f %F{magenta}\$%f '" > .zshrc
print -r -- "alias dealer='\"\$DEALER_CLI\"'" >> .zshrc
print -r -- "HISTFILE=/dev/null" >> .zshrc
# Ghostty's shell integration, so Dealer knows when a pane is idle (no "process running" prompts).
# Its titles are full paths (`/tmp/demo/api`); the tour's tabs read better with the project's name
# while idle and the command while one runs, so the shell sets those itself.
print -r -- 'GHOSTTY_SHELL_FEATURES=${GHOSTTY_SHELL_FEATURES//title/}' >> .zshrc
print -r -- '[[ -n $GHOSTTY_RESOURCES_DIR ]] && source "$GHOSTTY_RESOURCES_DIR"/shell-integration/zsh/ghostty-integration' >> .zshrc
print -r -- 'precmd() { print -Pn "\e]2;%1~\a" }' >> .zshrc
print -r -- 'preexec() { print -rn -- $'"'"'\e]2;'"'"'"${1//[[:cntrl:]]}"$'"'"'\a'"'"' }' >> .zshrc
: > .zshenv
G=(git -c user.name=demo -c user.email=demo@example.com)
cd api
printf '.lib\n' > .gitignore
printf 'test:\n\t@echo "  ok  42 passed (1.3s)"\n' > Makefile
printf '# api\n' > README.md
printf '12:00:01 GET /health 200\n12:00:02 GET /api/items 200\n12:00:04 POST /api/items 201\n' > server.log
# The tour's release script reports its progress with OSC 7501 through the repo's own helper.
cp $ROOT/scripts/demo/release.sh release.sh
cp $ROOT/scripts/lib/program-status.sh .lib/program-status.sh
git init -q -b main
$G add Makefile README.md .gitignore release.sh && $G commit -qm "Initial project"
$G add server.log && $G commit -qm "Add request log"
touch src/app.js tests/app.test.js && $G add src tests && $G commit -qm "Add items API and tests"
cd ../web
printf 'test:\n\t@echo "  ok  18 passed (0.9s)"\n' > Makefile
touch src/index.html src/hero.js src/app.css
git init -q -b main && $G add -A && $G commit -qm "Landing page"
cd ../docs
printf '# docs\n' > README.md; printf '# Getting started\n' > guide.md
git init -q -b main && $G add -A && $G commit -qm "Docs"
cd $DEMO_DIR
# Stand-ins on the shells' PATH, hidden from `ls` and git (#79, #81). Dealer tells Claude Code by
# its argv, so a script named `claude` gets Claude's working mark. It reports a turn the way Claude
# does (OSC 9;4;3 and a `◐` title, see docs/claude-code-states.md) and stays in the foreground like
# Claude, so progress isn't dropped as stale (#83). What it does next is the demo's call, so beats
# line up with captions (#98): Demo.swift writes `ask`, `done` or `fail` to .signal/<DEALER_PANE_ID>.
mkdir -p .bin .signal
print -r -- 'path=("$ZDOTDIR/.bin" $path)' >> .zshrc
cat > .bin/claude <<'SH'
#!/bin/sh
sig="$ZDOTDIR/.signal/$DEALER_PANE_ID"
topic=$(printf '%s' "$*" | awk '{ print toupper(substr($0, 1, 1)) substr($0, 2) }')
working() { printf '\033]2;\342\227\220 %s\a\033]9;4;3\a\342\234\273 Working\342\200\246\n' "$topic"; }
idle() { printf '\033]9;4;0\a\033]2;\342\234\263 %s\a' "$topic"; }
printf '\033[2m> %s\033[0m\n\n' "$*"
working
while :; do
  while [ ! -s "$sig" ]; do sleep 0.2; done
  next=$(cat "$sig"); rm -f "$sig"
  case $next in
    ask)
      idle
      "$DEALER_CLI" notify --state waiting --title "$topic" --body 'Permission needed'
      printf '\n  Edit tests/login.test.js\n  Allow this edit? (y/n) '
      read -r _
      printf '\n'; working ;;
    done)
      idle
      printf '\n\342\234\223 Done: GET /items takes ?cursor= and ?limit= (3 files changed)\n'
      "$DEALER_CLI" notify --state done --title "$topic" --body 'Finished' ;;
    fail)
      # A turn that ends in an API error: Dealer's StopFailure hook marks the pane failed.
      idle
      printf '\n\342\216\277 API Error: 529 Overloaded. Try again in a moment.\n'
      "$DEALER_CLI" notify --state failed --title "$topic" --body 'API Error: 529 Overloaded' ;;
  esac
done
SH
chmod +x .bin/claude
cd $ROOT

# Bounds (points, top-left origin) of our own Dealer window, by PID, plus the display scale.
BOUNDS=$OUT/.bounds
[[ -x $BOUNDS ]] || { print -r -- 'import CoreGraphics
let pid = Int(CommandLine.arguments[1])!
for w in CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as! [[String: Any]]
where (w[kCGWindowOwnerPID as String] as? Int) == pid && (w[kCGWindowLayer as String] as? Int ?? -1) >= 0 {
  // The demo window floats (layer > 0); skip small helper windows, and the menu bar, which is
  // the app's own full-width window once it's frontmost (the focus step below made the tour
  // record the menu bar instead of the demo).
  let b = w[kCGWindowBounds as String] as! [String: Double]
  guard b["Width"]! > 300, b["Height"]! > 300 else { continue }
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
  program_status working "Demos: recording $demo" "demo $(( ${DEMOS[(i)$demo]} )) of $#DEMOS; hands off the machine" $(( 100 * (${DEMOS[(i)$demo]} - 1) / $#DEMOS ))
  DEALER_SELFTEST=1 DEALER_DEMO=$demo DEALER_DEMO_DIR=$DEMO_DIR $BIN > $OUT/$demo.log 2>&1 &
  PID=$!  # killed by the EXIT trap if the script stops early
  sleep 1.5
  # Focus the window so macOS renders its active appearance (traffic lights, vibrancy).
  osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $PID) to true" 2>/dev/null || true
  B=($($BOUNDS $PID)); SCALE=${B[5]}
  (( $#B == 5 )) || { print "no Dealer window found"; exit 1; }
  CROP="$((B[3]*SCALE)):$((B[4]*SCALE)):$((B[1]*SCALE)):$((B[2]*SCALE))"
  ffmpeg -v error -y -f avfoundation -pixel_format bgr0 -capture_cursor 0 -framerate 30 -t 150 -i "$SCREEN:none" \
    -vf "crop=$CROP" -c:v libx264 -crf 16 -pix_fmt yuv420p $OUT/$demo-raw.mp4 2>/dev/null &
  FF=$!
  # Stop recording when the demo says it's done, while its window is still up: frames after the
  # window closes would show the user's screen. Only then does the app exit.
  until grep -q "DEMO DONE" $OUT/$demo.log 2>/dev/null || ! kill -0 $PID 2>/dev/null; do sleep 0.1; done
  kill -INT $FF; wait $FF || true
  grep -q "DEMO DONE" $OUT/$demo.log || { print "$demo exited without finishing; discarding"; rm -f $OUT/$demo-raw.mp4; exit 1; }
  while kill -0 $PID 2>/dev/null; do sleep 0.2; done
  PID=
  # A beat whose condition never came (`mouse.until`) ran on regardless; the take is likely wrong.
  if grep -q "DEMO TIMEOUT" $OUT/$demo.log; then
    print "$demo: a beat timed out (see $OUT/$demo.log); check the take or record it again"
  fi
  program_status working "Demos: encoding $demo" "MP4 and contact sheets"
  encode $demo
done
program_status done "Demos recorded" "Review the contact sheets in $OUT/review before publishing"
