# Building libghostty without Xcode

`scripts/build-ghosttykit.sh` builds `vendor/GhosttyKit.xcframework` with only zig and the
Command Line Tools. It does this by building Ghostty from a temporary clone with a small patch and
a precompiled shader library. Everything for this lives in this directory and in one marked block of
`build-ghosttykit.sh` (#42).

## Why

Ghostty's stock xcframework build has three steps that need full Xcode, even with
`-Dxcframework-target=native`:

1. It configures the iOS and iOS-simulator libraries regardless of the target, and those call
   zig's `findNative`, which needs the iPhoneOS SDK (`DarwinSdkNotFound` under the Command Line Tools).
2. It compiles `src/renderer/shaders/shaders.metal` with `xcrun metal`. `metal` ships only in Xcode's
   separately downloaded Metal Toolchain, never in the Command Line Tools.
3. It wraps the library with `xcodebuild -create-xcframework`, which is Xcode only.

So a contributor without Xcode couldn't produce `vendor/` at all (#42). Steps 1 and 3 are
packaging details. Step 2 produces a 52 KB file that only changes when the shader source changes,
and that source didn't change in the 1,642 upstream commits after our pin.

**Decision:** carry a patch to Ghostty's build that skips the unneeded iOS graphs, adds a
`-Dmetallib=<path>` option to embed a precompiled `Ghostty.metallib`, and writes the
single-library xcframework without `xcodebuild`. Commit the metallib per pin, with its provenance
and a hash of the shader source that the build script checks. Everyone builds `vendor/` from source
locally. Only regenerating the metallib needs Xcode, and only when the shaders change.

## Alternatives considered

- **A. CI on a macOS runner, publishing the framework as a release asset.** This is a new piece of
  infrastructure. GitHub's macOS images usually include the Metal Toolchain but have dropped it at
  times (actions/runner-images #13014, #14013). macOS minutes count 10× on a private repo, and
  downloads from a private repo need `gh` auth. Each user downloads 33 MB (arm64) or about 66 MB
  (universal) per pin.
- **B. A maintainer uploads a release asset by hand.** Same downloads and auth as A, and its
  provenance is one person's machine.
- **C. Commit the framework to a binary branch.** That adds 33–66 MB to every clone per pin,
  permanently, close to GitHub's 100 MB file limit.
- **D (chosen).** Nothing to host or download. The only binary is 52 KB, and its source hash is
  checked. The cost is rebasing a ~45-line patch at pin bumps.

## What's here

| File | What it is |
|---|---|
| `<pin12>.patch` | The patch to Ghostty's `src/build/`, applied to a temporary clone (never your checkout). Its header explains each hunk. |
| `<pin12>.metallib` | `Ghostty.metallib` compiled from the pin's `shaders.metal`, byte-identical to the stock build's. Passed as `-Dmetallib`. |
| `<pin12>.metallib.txt` | Provenance: pin, `shaders_sha256` (checked before every build), `metallib_sha256` (checked), the Xcode/metal versions, and the regenerate command. |
| `<pin12>.runtime.patch` | Dealer's runtime patch (#89, below), applied to the same temporary clone. Its header explains each hunk. |
| `runtime.version` | The marker stamped on a library built with the runtime patch (`dealer.1`). |

`build-ghosttykit.sh` options: `--no-patch` skips the #42 build patch and uses Ghostty's stock
build steps (needs Xcode), to compare against or fall back to. It still applies the runtime patch,
in a temporary clone too. `--compile-metallib` regenerates the metallib and provenance (needs Xcode).

## Runtime patch (#89)

Unlike the build patch, `<pin12>.runtime.patch` changes what libghostty does. Ghostty parses and
validates OSC 7501 (Program Status Protocol) since v1.4.0, but only libghostty-vt passes it on; the
app runtime that Dealer embeds drops it. The patch passes each report's validated body to the
embedder as `GHOSTTY_ACTION_PROGRAM_STATUS`, sends `state=clear` on a full reset, and answers the
support query (`OSC 7501 ; ?`) on the read thread, where the reply is queued before the reply to a
following `CSI c`. Dealer couldn't answer it in time from the app side.

- **ABI:** the new tag is the last in `ghostty_action_tag_e` and the new union member is 16 bytes,
  so `ghostty_action_u` keeps its size. A patched library works with Swift code that predates it.
  Swift that uses the tag needs the patched header.
- **Marker:** `build-ghosttykit.sh` always passes `-Dversion-string=X.Y.Z-<marker>+<pin12>`
  (`1.4.0-dealer.1+83fb95624b04`). `check-ghostty.sh` and the app (`GhosttyVersion.runtimeMarker`,
  banner) require it, so a stock library at the pinned commit fails the check instead of quietly
  lacking OSC 7501. The pre-release part only makes Ghostty's `release_channel` `tip`, which seeds
  nothing but `auto-update-channel` (Sparkle, unused). Never put the marker after the hash:
  `GhosttyVersion.commit(of:)` would then see no commit, and the banner would stay silent.
- **Changing it:** edit the patch, bump the number in `runtime.version` and
  `GhosttyVersion.runtimeMarker` together (the self-test compares them), and rebuild `vendor/`.
- **Removing it:** once upstream's app runtime passes OSC 7501 on, bump the pin, delete
  `<pin12>.runtime.patch` and `runtime.version`, the marker block in `build-ghosttykit.sh` (use
  Ghostty's own version string again, with the `X.Y.Z+<hash>` fix-up at release tags, #85), the
  marker checks in `check-ghostty.sh` and `GhosttyVersion`, and switch Dealer's Swift to upstream's
  action.

## Pin bumps

1. Bump `scripts/ghostty.version` as usual, and check out the new pin in a `git clone --shared`.
2. Rebase both patches: apply each old one in the clone (`git apply --3way`), fix the conflicts, and
   save `git diff` as `<newpin12>.patch` / `<newpin12>.runtime.patch` under the old header (keep one
   line per hunk). Delete the old pin's files. Check whether upstream now passes OSC 7501 to the
   apprt itself; if so, drop the runtime patch (above).
3. Run `build-ghosttykit.sh`. If it reports a shaders.metal mismatch, regenerate on a Mac with Xcode
   (`--compile-metallib`) and commit the new `.metallib` and `.metallib.txt`. If it doesn't, copy the
   old metallib and provenance to the new names and update `pin=`.

## Verify

```sh
DEVELOPER_DIR=/Library/Developer/CommandLineTools scripts/build-ghosttykit.sh --out /tmp/gk
scripts/check-ghostty.sh /tmp/gk/GhosttyKit.xcframework
```

Then build Dealer against it and run the self-test (see CLAUDE.md). To compare with the stock
build steps, run `--no-patch --out /tmp/gk-stock` with Xcode selected. The metallib embedded in both is
the same, and so are the xcframework layout and `Info.plist` keys.

## Removing this

Once it's gone, building `vendor/` needs full Xcode plus its Metal Toolchain
(`xcodebuild -downloadComponent MetalToolchain`).

1. Delete `scripts/ghostty-build/`.
2. In `scripts/build-ghosttykit.sh`, delete:
   - the block between the `Building without Xcode (#42)` and `end of the #42 block` banners;
   - the `--no-patch` and `--compile-metallib` lines in the usage comment, the option parser and the
     `NOPATCH=0`/`COMPILE_METALLIB=0` defaults;
   - the paragraph about the Command Line Tools in the header.
   Then make the `metal`/`xcodebuild` preflight unconditional, and set `EXTRA=` where the block was.
   Keep `clone_tree` above it: the runtime patch (#89) still builds in a temporary clone.
3. Remove the pointers to this README from `CLAUDE.md` and `README.md` (Building), and from
   `docs/orchestrator-handoff.md`.

## When it becomes unnecessary

- The iOS hunks went at the zig 0.16 pin bump (b1d9492cf, #43): upstream 7a171895d stopped building
  iOS libraries.
- At v1.4.0 (#85) the XCFrameworkStep hunk was rebased onto upstream's restructured step
  (`out_path` union, headers as directory args); the sh writer itself is unchanged.
- The rest goes if upstream adds a way to use a precompiled metallib and a path that doesn't need
  `xcodebuild`. Both would be reasonable to propose upstream. Until then, the patch is the only
  thing that can drift.
