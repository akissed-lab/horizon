# Aksi (Horizon on iOS, arm64, experimental)

The same game as the desktop and Android builds, as a native `.app`/`.ipa`, branded **Aksi** on the
home screen (the bundle and the `.ipa` keep the name `Horizon`). There is no Xcode project:
`packaging/ios/launcher.m` is a small UIKit launcher that owns the app before the engine starts,
`crates/horizon-ios` compiles horizon-client's game (`src/game.rs` + `src/game/`) into
`libhorizon.a`, with `crates/horizon-client/src/ios_main.rs` as its entry point instead of
`main.rs`, and `packaging/ios/build_ipa.sh` links the two together. Rendering is wgpu on Metal,
sound is cpal on CoreAudio, and input is winit's UIKit backend.

**Status: experimental.** The macOS workflow builds, ad-hoc signs and packages `Horizon.ipa`, and
the app runs on a phone; treat it as an experiment. Logs are in `Documents/Horizon/logs/latest.log`
and crashes in `Documents/Horizon/crash-reports/`, both readable in the Files app.

Unlike the Android build there is **no in-app game-file downloader** and **no Microsoft login**:
the game files are prepared on a PC and copied to the phone once (see "Game files"). The app opens
in the native **Aksi launcher** — Continue, all worlds, a new world, multiplayer, settings and the
Ely.by account — and only starts the engine when Play is pressed.

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

The workflow is `.github/workflows/ios.yml`; it runs `packaging/ios/build_ipa.sh` on `macos-15`.
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
4. Launch Aksi once. It creates `On My iPhone → Aksi` (the app's `Documents/Horizon`).

With AltStore or Sideloadly, drag the IPA into the app on the computer and sign as usual.

The IPA is arm64 only and has no app extensions. Uninstalling the app deletes its folder,
including worlds and game files, so back up `saves/` before deleting it.

## Launcher

The first screen is a native UIKit menu, not the engine: nothing is loaded until you press Play, so
a phone with no game files still opens the app and explains what is missing.

- **Continue** opens the most recently modified world in `saves/`; with no worlds it opens the
  new-world form instead.
- **All worlds** lists the folders in `saves/` that contain `level.dat`, newest first.
- **New world** takes a name, an optional seed and the creative/gamemode switch, then creates the
  folder and opens it. The name becomes the folder name, as in vanilla.
- **Multiplayer** connects to a server address directly (`host` or `host:port`); offline-mode
  servers only, since there is no session join.
- **Settings** holds the accent colour (the game's eight-colour palette) and the memory preset
  (Economy / Normal / Maximum), stored in `horizon-launcher.txt`. The preset sets render and
  simulation distance, the FPS cap and particles, and is applied at startup and again each time a
  world starts from the launcher. The Aksi screen in the pause menu edits the same settings while
  you play.
- **Account** is the Ely.by sign-in: nickname and password go to `authserver.ely.by` with
  `NSURLSession` (the system TLS stack), and only the nickname, UUID, skin and skin model are kept
  on the phone. The password and access token are never written or logged.

Play hands your choice to `horizon_ios_main`, which starts the game and joins the running
`UIApplication`; from then on Play uses the already-running winit loop. Closing a world — Save and
Quit to Title, or leaving a server — brings the same launcher back, with the world list refreshed.
The launcher writes `horizon-launch.txt` and the game deletes it after reading it: `world:<folder>`,
`new:<name>` (plus `seed:` and `creative:`), or `server:<address>`.

## Game files

Horizon never ships Minecraft's files. Prepare them **on a PC** (needs Java; the same output as
the desktop and Android builds — see `README.md`):

```sh
cargo run --release -p horizon-prepare -- --prepare --server-jar ~/Downloads/server.jar
cargo run --release -p horizon-prepare -- sounds    # optional
```

The result is `.local/horizon-client/26.3/`, the folder with `horizon-resources.json` in it.
Copy its **contents** (not the folder itself) into the app:

- **Finder** (macOS or Windows with iTunes/Apple Devices): iPhone → Files → **Aksi** →
  `Documents/Horizon/resources/`, or
- **Files app** on the phone: **On My iPhone → Aksi → resources**.

After copying, `Documents/Horizon/resources/horizon-resources.json` must exist. When updating,
choose "Replace" so stale files do not stay behind. The launcher checks this file on every screen
and re-enables Play as soon as it appears, so there is no need to reinstall.

The app's home and working directory is `Documents/Horizon`; it shows up in Finder and the Files
app because `Info.plist` sets `UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace`.

```
Documents/Horizon/
  resources/            # the prepared game files; horizon-resources.json lives here
  options.txt
  saves/                # worlds; copy existing ones here
  resourcepacks/
  shaderpacks/
  horizon-account.txt   # Ely.by name and UUID, for the Account screen
  horizon-player.txt    # the nickname the game joins with
  horizon-skin.png      # the Ely.by skin, if one is set
  horizon-skin.txt      # "model:slim" or "model:classic"
  horizon-launcher.txt  # the launcher's accent and memory preset
  logs/latest.log
  logs/launcher.log     # the launcher's own log (start, sign-in, launches)
  crash-reports/
```

`HORIZON_RESOURCES` points at `resources/`, and `HORIZON_CACHE` at the app's
`Library/Caches/horizon`. Worlds from a PC or Android build go into `saves/` the same way.

## Controls

The launcher is a normal UIKit app: tap a card to pick a world or screen, and the system keyboard
appears in text fields. In the game, touch controls are the same as on Android (`game/touch.rs`): a
movement joystick, look by dragging, jump/sneak, hotbar, and the inventory, pause, chat and emote
buttons. In menus a finger is the mouse (tap = click, drag = scroll); over a screen in the world
there is a close button that sends Escape.

The layout editor (the gear) writes `touch_layout.json` in the game folder on every change — a
drag, a size or fade tap, a preset, even leaving with the back gesture — and the app saves it again
when iOS suspends it, so controls no longer reset after a relaunch. `options.txt` is saved the same
way; the log names both paths and any write error.

A Bluetooth or USB keyboard and mouse work through winit. Controllers do not: `gilrs` has no iOS
backend, so the `controllers` feature stays off.

iOS is **landscape only**, like the Android build's `sensorLandscape`: the game fills the whole
display, drawing under the status bar, the notch and the home indicator, and sizes its framebuffer
from the window's outer size (winit's `inner_size` stops at the safe area and would stretch the
picture).

The app also defers the system's screen-edge gestures (`preferredScreenEdgesDeferringSystemGestures`):
a swipe up from the bottom or down from the top only shows a hint the first time and needs a second,
deliberate swipe, so a stray finger no longer sends the game Home or opens Control Center. That is the
same protection games get from Guided Access, without turning it on.

**On-screen keyboard.** Tapping a text field — chat, a command, a sign, an anvil, the server
address, a search box, or the Ely.by nickname and password — switches winit's input method on
(`set_ime_allowed`), which makes the view first responder and shows the iOS keyboard. The candidate
window follows the caret (`set_ime_cursor_area`), committed text goes through the same sinks as a
hardware keyboard, and Return in the Ely.by fields submits the form. Closing the field hides the
keyboard again. A Bluetooth or USB keyboard still works the same way.

## Known limitations

- **Experimental:** it runs on a phone, but expect crashes, a black screen or an early exit; the
  log is the first place to look.
- **Memory:** about 2.2 GB. Use a 6 GB+ device, and set render distance to 4–6. A 4 GB phone will
  usually be killed when a world loads.
- **No Microsoft login:** v1 plays local worlds, offline-mode servers and Ely.by accounts. Online-mode
  servers need the session join flow, which is not wired up.
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

- **Play does nothing / "Нет ресурсов Minecraft":** `Documents/Horizon/resources/horizon-resources.json`
  is missing or incomplete. Copy the prepared folder again; the folder, not just its contents
  one level up, must be `resources/`. Play enables itself once the file is there.
- **The launcher closes immediately or shows "Игра не запустилась":** read
  `Documents/Horizon/logs/latest.log` and the newest `crash-reports/` file (Files app → Horizon).
  A log that stops at Metal/device setup points at the GPU; one that stops while loading a world
  usually means memory. The launcher's own lines are in `logs/launcher.log`.
- **The IPA will not install:** uninstall the old copy first, check the certificate is trusted,
  and remember a free Apple ID is limited to a few apps and expires after 7 days.
- **Black screen with a running app:** the renderer may have failed before the first frame.
  The log records each backend step; please attach it to a bug report.
- **Where is the log?** `On My iPhone → Aksi → logs → latest.log`. It can be shared from the
  Files app without a computer.

## How it is put together

| Path | What it does |
| --- | --- |
| `crates/horizon-ios/Cargo.toml` | `staticlib` named `horizon`, crate root `../horizon-client/src/ios_main.rs` |
| `crates/horizon-client/src/ios_main.rs` | C entry points: `horizon_ios_main` (sets `HORIZON_HOME`/`HORIZON_RESOURCES`/`HORIZON_CACHE`, logging and crash reports, raises the file limit, runs `game::run`) and `horizon_ios_launch_action` (hands a later Play press to the running loop) |
| `packaging/ios/main.m` | `main` that calls `UIApplicationMain` with the launcher's delegate; UIKit therefore starts before the engine |
| `packaging/ios/launcher.h`, `launcher.m` | the UIKit launcher: home, worlds, new world, multiplayer, settings, paths, the shared look, and starting/presenting the game |
| `packaging/ios/launcher_ely.m` | the Ely.by sign-in screen: `NSURLSession` request, profile validation, skin and model download, sign-out |
| `packaging/ios/build_ipa.sh` | cargo build, `clang` compile and link with the frameworks, `Info.plist`, icons, ad-hoc `codesign`, `zip` |
| `packaging/ios/Info.plist` | bundle id, minimum iOS 15, Files/Finder sharing, launch screen, landscape-only orientations, legacy icon list |
| `.github/workflows/ios.yml` | macOS runner build, artifact, release on tags |

The game code differs from the desktop build only where the platform does: Metal is the only
backend (`gfx.rs`), the first run's defaults fit a phone (`settings.rs`), touch controls and the
mobile background/suspend handling cover iOS as well as Android, and the desktop clipboard and
`open` integrations are compiled out.

The one deviation from upstream winit is deliberate: `third_party/winit`'s iOS `EventLoop::run`
joins a `UIApplication` that is already running (the launcher's) instead of calling
`UIApplicationMain` itself, creates its observers, sends `Resumed` (the launch notification already
fired) and returns. `crates/horizon-client/src/game/ios_launcher.rs` is the bridge: it reads
`horizon-launch.txt`, applies the launcher's settings, queues a later Play press until the engine's
loop drains it, and asks the launcher back when a world closes. Because `run_app` needs a `'static`
closure, the engine's `App` is leaked on iOS and the launch game loop runs inside UIKit's run loop.

The bundle has no asset catalog (there is no Xcode project), so the icons are PNGs at the bundle
root named `Icon-60@2x.png` and so on, generated from `packaging/icons/ios-1024.png` by `sips`,
and listed with the legacy `CFBundleIcons`/`CFBundleIconFiles` keys. ESign and Feather read those
without trouble.
