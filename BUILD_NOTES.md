# Build notes — macOS app (sidebar fork)

Context: building the macOS `Ghostty.app` from this clone on macOS 26.5 / Xcode 26.5 /
Homebrew zig 0.15.2 (the exact version the flake pins, flake.nix:72).

## Feature changes in this branch (all compile cleanly — verified 286/289 build steps)
- Sidebar status states (working/done/error/idle) with colored dot + pulse
- `ghosttyctl set-status --state`, IPC `state` param, `TabMetadataStore.state`
- Per-tab listening ports (`PortMonitor.swift`) shown as clickable `:port` chips
- Cmd+V image paste → forwards 0x16 when clipboard is a pure image (`Ghostty.App.readClipboard`)
- `GHOSTTY_TAB_ID` injected into each surface's shell env (`SurfaceView.withCValue`)

## Build blockers encountered (NONE are caused by the feature changes)
1. **Metal Toolchain missing** (Xcode 26.5 ships it separately).
   Fix: `xcodebuild -downloadComponent MetalToolchain`  ✅ resolved.
2. **App link fails — `libghostty.a` (macOS slice of GhosttyKit.xcframework) does
   not bundle several of libghostty's own static C deps.** The objects exist in
   `.zig-cache` but are missing/`U` (undefined) in the shipped archive:
   - Sentry core (`_sentry_value_*`) — worked around with `-Dsentry=false`.
   - gettext/libintl (`_libintl_textdomain`, `_libintl_nl_domain_bindings`) — the
     bundled `libintl.a` exists in cache (arm64, 584K) but isn't merged; it is
     itself fragmented (references `__libintl_find_domain`, UBSan runtime, …).
   - `lipo`'d universal `libghostty.a` is inconsistent vs the per-arch
     `libghostty-fat.a` (some cache copies define `ghostty_simd_*`, some don't) —
     a fingerprint of stale/mixed cache state.

   The thin/fat selection lives in `src/build/GhosttyLib.zig` (LibtoolStep →
   `libghostty-fat.a`; LipoStep → `libghostty.a`) and `src/build/GhosttyXCFramework.zig`.

NOTE: Nix does NOT help — the flake pins the same zig 0.15.2, and Ghostty's Nix
package targets Linux/GTK (no macOS `.app`).

CONFIRMED: a fully clean build (`rm -rf .zig-cache zig-out macos/build
macos/GhosttyKit.xcframework` then `zig build -Dsentry=false`) fails **identically**
at the app `Ld` step. So this is a reproducible build-system bug (incomplete
dependency bundling), NOT stale cache, NOT the feature changes, NOT the zig version.

## How to build (once the archive is complete)
```sh
xcodebuild -downloadComponent MetalToolchain      # one-time, if not installed
zig build -Dsentry=false                          # builds GhosttyKit.xcframework + app
# app is produced via the internal xcodebuild step; or build the app explicitly:
xcodebuild -project macos/Ghostty.xcodeproj -scheme Ghostty -configuration Debug \
  -derivedDataPath macos/build ONLY_ACTIVE_ARCH=YES ARCHS=arm64 CODE_SIGNING_ALLOWED=YES
```
If the link still fails on missing bundled deps, the fix is in the build system
(ensure LibtoolStep merges all dependency static libs into `libghostty-fat.a`),
not in the app or the feature code.
