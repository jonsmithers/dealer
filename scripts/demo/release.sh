#!/bin/sh
# The README tour's release script (#98): record-demo.sh copies it into the demo project as
# ./release.sh, with scripts/lib/program-status.sh as .lib/program-status.sh. It does nothing but
# report its progress to the terminal the standard way (OSC 7501, Program Status Protocol), 0 to
# 100 % over about RELEASE_SECONDS (default 12), then `done`, so the tab's ring fills as it goes.
. "$(dirname "$0")/.lib/program-status.sh"
program_status_init release release
trap 'program_status_exit $?' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

version=v0.4.0
pause=$(awk "BEGIN { print ${RELEASE_SECONDS:-12} / 20 }")
pct=0
for phase in "Building $version" "Running tests" "Packaging" "Publishing"; do
  printf '\033[1;34m==>\033[0m %s\n' "$phase"
  for _ in 1 2 3 4 5; do
    program_status working "Release $version" "$phase" $pct
    sleep "$pause"
    pct=$((pct + 5))
  done
done
program_status working "Release $version" "Publishing" 100
sleep "$pause"
program_status done "Released $version" "app $version is live"
printf '\033[1;32m==>\033[0m Released %s\n' "$version"
