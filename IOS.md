# Horizon on iOS (arm64, experimental)

The same game as the desktop and Android builds, as a native `.app`/`.ipa`. There is no Xcode
project: `crates/horizon-ios` compiles horizon-client's game (`src/game.rs` + `src/game/`) into
`libhorizon.a`, with `crates/horizon-client/src/ios_main.rs` as its entry point instead of
`main.rs`, and `packaging/ios/build_ipa.sh` links it against `packaging/ios/main.m`. Rendering is
wgpu on Metal, sound is cpal on CoreAudio, and input is winit's UIKit backend.

**Status: the Rust side compiles for `aarch64-apple-ios` and the workflow builds and signs the
bundle; it has not been run on a phone yet.** Treat it as an experiment. Logs are in
`Documents/Horizon/logs/latest.log` and crashes in `Documents/Horizon/crash-reports/`, both
readable in the Files app.

Unlike the Android build there is **no in-app game-file downloader** and **no Microsoft login**:
the game files are prepared on a PC and copied to the phone once (see "Game files"), and the app
starts straight into the title screen.

## Requirements

- An arm64 iPhone or iPad on **iOS 15 or newer** with Metal (every device that runs iOS 15).
- **6 GB of RAM or more** recommended. The game takes about 2.2 GB; on a 4 GB phone or with a
  large render distance iOS kills the app (jetsam).
- Game files prepared on a PC (Java, see below).
- A way to sideload: **ESign**, **Feather**, **AltStore/Sideloadly**, or TrollStore. A free Apple
  ID certificate works but expires after 7 days; a paid developer certificate lasts a year.

There is no App Store distribution: this is an unofficial port, and the game files are not ours
to ship.

## Build

### GitHub Actions (recommended)

The repository builds the IPA on GitHub's macOS runners, so no Mac is needed:

1. Fork this repository and enable Actions in the fork.
2. Push to the `ios` branch (or `main`/`android-port` if you rename it), or run the **ios**
   workflow from the Actions tab (`workflow_dispatch`, with a `release` or `fast` profile).
3. Download the `Horizon-ios-<sha>` artifact. Pushing a `v*` tag also publishes
   `Horizon.ipa` as a release asset, which is the easiest file to open on the phone.

The workflow is `.github/workflows/ios.yml`; it runs `packaging/ios/build_ipa.sh` on `macos-14`.
It does not need any secrets: the IPA is unsigned apart from an ad-hoc signature, and the
signing app re-signs it.

### On a Mac

```sh
rustup target add aarch64-apple-ios
./packaging/ios/build_ipa.sh                 # -> target/ios/Horizon.ipa
PROFILE=fast ./packaging/ios/build_ipa.sh    # much quicker to build, slower game
```

Needs macOS with Xcode's command line tools (`clang`, `sips`, `codesign`, `plutil`, `zip`).
`PROFILE=release` (the default) uses thin LTO and one codegen unit.

Environment variables:

| Variable | Default | Meaning |
| --- | --- | --- |
| `PROFILE` | `release` | Cargo profile (`release` or `fast`) |
| `HORIZON_BUNDLE_ID` | `dev.horizonlab.horizon` | `CFBundleIdentifier` |
| `HORIZON_VERSION` | `crates/horizon-ios/Cargo.toml` | `CFBundleShortVersionString` |
| `IOS_MIN_VERSION` | `15.0` | Deployment target in the `-target` triple |
| `IOS_SDK` | `iphoneos` | `xcrun` SDK name |
| `IOS_SIGN_IDENTITY` | `-` (ad-hoc) | `codesign` identity |
| `IOS_ENTITLEMENTS` | none | Entitlements file for a real identity |
| `CARGO_FLAGS` | none | Extra `cargo build` flags, e.g. `--features mods` |

`--features mods` is untested on iOS; native `.hnmod` mods are not supported.

## Install with ESign or Feather

1. Copy `Horizon.ipa` to the phone (release asset, or Finder's File Sharing, or a download).
2. Open it in ESign/Feather and sign it with your certificate. Keep the bundle id
   `dev.horizonlab.horizon` unless another app already uses it; the signing app can change it.
3. Install, then trust the certificate: **Settings → General → VPN & Device Management**.
4. Launch Horizon once. It creates `On My iPhone → Horizon` (the app's `Documents/Horizon`).

With AltStore or Sideloadly, drag the IPA into the app on the computer and sign as usual.

The IPA is arm64 only and has no app extensions. Uninstalling the app deletes its folder,
including worlds and game files, so back up `saves/` before deleting it.

## Game files

Horizon never ships Minecraft's files. Prepare them **on a PC** (needs Java; the same output as
the desktop and Android builds — see `README.md`):

```sh
cargo run --release -p horizon-prepare -- --prepare --server-jar ~/Downloads/server.jar
cargo run --release -p horizon-prepare -- sounds    # optional
```

The result is `.local/horizon-client/26.3/`, the folder with `horizon-resources.json` in it.
Copy its **contents** (not the folder itself) into the app:

- **Finder** (macOS or Windows with iTunes/Apple Devices): iPhone → Files → **Horizon** →
  `Documents/Horizon/resources/`, or
- **Files app** on the phone: **On My iPhone → Horizon → resources**.

After copying, `Documents/Horizon/resources/horizon-resources.json` must exist. When updating,
choose "Replace" so stale files do not stay behind.

The app's home and working directory is `Documents/Horizon`; it shows up in Finder and the Files
app because `Info.plist` sets `UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace`.

```
Documents/Horizon/
  resources/            # the prepared game files; horizon-resources.json lives here
  options.txt
  saves/                # worlds; copy existing ones here
  resourcepacks/
  shaderpacks/
  logs/latest.log
  crash-reports/
```

`HORIZON_RESOURCES` points at `resources/`, and `HORIZON_CACHE` at the app's
`Library/Caches/horizon`. Worlds from a PC or Android build go into `saves/` the same way.

## Controls

Touch controls are the same as on Android (`game/touch.rs`): a movement joystick, look by
dragging, jump/sneak, hotbar, and the inventory, pause, chat and emote buttons. In menus a finger
is the mouse (tap = click, drag = scroll); over a screen in the world there is a close button
that sends Escape.

A Bluetooth or USB keyboard and mouse work through winit. Controllers do not: `gilrs` has no iOS
backend, so the `controllers` feature stays off.

**There is no on-screen keyboard yet.** Chat, commands, signs, anvils, the server-address field
and search boxes cannot be typed into without a hardware keyboard. This is the largest v1
limitation and the first thing to fix with a UIKit text-input bridge (the Android build uses a
JNI bridge, `game/android_ime.rs`).

## Known limitations

- **Never run on a device.** Expect crashes, a black screen or an early exit; the log is the
  first place to look.
- **Memory:** about 2.2 GB. Use a 6 GB+ device, and set render distance to 4–6. A 4 GB phone will
  usually be killed when a world loads.
- **No Microsoft login:** v1 plays local worlds and offline-mode servers. Online-mode servers
  need the session join flow, which is not wired up.
- **No soft keyboard** (see above).
- **No in-app file downloader:** game files come from a PC (see "Game files").
- **Clipboard:** the game keeps an in-memory clipboard; copying to or pasting from other apps is
  not connected (arboard has no iOS backend here).
- **"Open folder" and links:** buttons that open a folder or a URL only write the location to the
  log; iOS has no `xdg-open`, and v1 has no UIKit URL opener. Use the Files app.
- **Mods:** Horizon's WebAssembly mods and native `.hnmod` libraries are off in v1. Resource packs
  and shader packs work like on desktop.
- **HDR** is desktop-only, and the Metal backend is the only graphics backend.
- **Quit** leaves through `exit(0)`: iOS gives apps no graceful way to quit themselves.
- An external display and Stage Manager are not handled specially; the window is fullscreen.

## Troubleshooting

- **"Horizon needs its game files" screen:** `Documents/Horizon/resources/horizon-resources.json`
  is missing or incomplete. Copy the prepared folder again; the folder, not just its contents
  one level up, must be `resources/`.
- **The app closes immediately:** read `Documents/Horizon/logs/latest.log` and the newest
  `crash-reports/` file (Files app → Horizon). A log that stops at Metal/device setup points at
  the GPU; one that stops while loading a world usually means memory.
- **The IPA will not install:** uninstall the old copy first, check the certificate is trusted,
  and remember a free Apple ID is limited to a few apps and expires after 7 days.
- **Black screen with a running app:** the renderer may have failed before the first frame.
  The log records each backend step; please attach it to a bug report.
- **Where is the log?** `On My iPhone → Horizon → logs → latest.log`. It can be shared from the
  Files app without a computer.

## How it is put together

| Path | What it does |
| --- | --- |
| `crates/horizon-ios/Cargo.toml` | `staticlib` named `horizon`, crate root `../horizon-client/src/ios_main.rs` |
| `crates/horizon-client/src/ios_main.rs` | C entry point: sets `HORIZON_HOME`/`HORIZON_RESOURCES`/`HORIZON_CACHE`, logging and crash reports, raises the file limit, runs `game::run` |
| `packaging/ios/main.m` | plain `main` that calls `horizon_ios_main()`; it must not start UIKit — winit's iOS backend calls `UIApplicationMain` itself and refuses to run afterwards |
| `packaging/ios/build_ipa.sh` | cargo build, `clang` link with the frameworks, `Info.plist`, icons, ad-hoc `codesign`, `zip` |
| `packaging/ios/Info.plist` | bundle id, minimum iOS 15, Files/Finder sharing, launch screen, orientations, legacy icon list |
| `.github/workflows/ios.yml` | macOS runner build, artifact, release on tags |

The game code differs from the desktop build only where the platform does: Metal is the only
backend (`gfx.rs`), the first run's defaults fit a phone (`settings.rs`), touch controls and the
mobile background/suspend handling cover iOS as well as Android, and the desktop clipboard and
`open` integrations are compiled out.

The bundle has no asset catalog (there is no Xcode project), so the icons are PNGs at the bundle
root named `Icon-60@2x.png` and so on, generated from `packaging/icons/ios-1024.png` by `sips`,
and listed with the legacy `CFBundleIcons`/`CFBundleIconFiles` keys. ESign and Feather read those
without trouble.
