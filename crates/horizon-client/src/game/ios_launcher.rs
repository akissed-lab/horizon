//! The bridge to the native UIKit launcher (`packaging/ios/launcher.m`).
//!
//! The launcher is shown before the engine exists: it writes
//! `horizon-launch.txt` with what the player chose (normally `title:`, the
//! game's own title screen; also a world or server), hides itself and calls
//! [`horizon_ios_main`](super::run) through the C entry point.
//! Once the game is running, closing a world brings the same launcher back; its
//! Play button then writes the file again and calls the C shim
//! `horizon_ios_launch_action`, which queues the action and wakes the winit
//! loop through its proxy. The leaked `App` applies it on the main thread.
//!
//! The launcher also keeps `horizon-launcher.txt` (`accent:`, `memory:` and
//! the other controls), which [`apply_launcher_settings`] folds into the
//! settings at startup, and the nickname files, which [`apply_identity`] reads
//! before the game is built.
use super::{Game, Options, PendingWorldEntry};
use horizon_client::{
    Result,
    extras::{ACCENTS, MEMORY},
    settings::Settings,
    title::parse_seed,
};
use std::sync::{
    Mutex,
    atomic::{AtomicBool, Ordering},
};

/// Written by the launcher, read and removed by the game.
const LAUNCH_FILE: &str = "horizon-launch.txt";
/// The launcher's own settings, read at startup and never written here.
const SETTINGS_FILE: &str = "horizon-launcher.txt";

/// What the launcher's Play button asked for.
pub(super) enum Launch {
    /// No world: the game's own title and world list, where the player picks.
    Title,
    /// An existing save folder.
    World(String),
    /// A new world: its display name, optional seed and game mode.
    New {
        name: String,
        seed: Option<i64>,
        creative: bool,
    },
    /// A multiplayer address.
    Server(String),
}

static PROXY: Mutex<Option<winit::event_loop::EventLoopProxy<()>>> = Mutex::new(None);
static QUEUE: Mutex<Vec<Launch>> = Mutex::new(Vec::new());
/// The launcher window is over the game window: stop drawing until an action
/// arrives (`Game::about_to_wait`).
static SHOWN: AtomicBool = AtomicBool::new(false);

unsafe extern "C" {
    /// In `packaging/ios/launcher.m`: brings the launcher window back.
    fn horizon_ios_present_launcher();
}

/// Keep the proxy that wakes the winit loop for post-game launch actions.
pub(super) fn install_proxy(proxy: winit::event_loop::EventLoopProxy<()>) {
    if let Ok(mut slot) = PROXY.lock() {
        *slot = Some(proxy);
    }
}

/// True while the native launcher covers the game.
pub(super) fn launcher_shown() -> bool {
    SHOWN.load(Ordering::Relaxed)
}

/// Bring the native launcher back, over the (idle) game window.
pub(super) fn present() {
    SHOWN.store(true, Ordering::Relaxed);
    // SAFETY: called from the winit callback on the main thread; the function
    // only re-shows a window and dispatches to the main queue.
    unsafe { horizon_ios_present_launcher() };
}

/// Called by the C shim after a post-game Play: read the file, queue it and
/// wake the loop.
pub(super) fn launch_action_from_launcher() {
    let Some(launch) = take_launch() else {
        return;
    };
    if let Ok(mut queue) = QUEUE.lock() {
        queue.push(launch);
    }
    if let Ok(slot) = PROXY.lock()
        && let Some(proxy) = slot.as_ref()
    {
        let _ = proxy.send_event(());
    }
}

/// Apply every queued action on the game's main thread.
pub(super) fn drain(game: &mut Game<'_>) {
    let actions: Vec<Launch> = match QUEUE.lock() {
        Ok(mut queue) => queue.drain(..).collect(),
        Err(_) => return,
    };
    for launch in actions {
        SHOWN.store(false, Ordering::Relaxed);
        if let Err(error) = apply(game, launch) {
            log::error!("Horizon: the launcher's world could not start: {error}");
            present();
        }
    }
}

/// Read and remove `horizon-launch.txt`.
pub(super) fn take_launch() -> Option<Launch> {
    let text = std::fs::read_to_string(LAUNCH_FILE).ok()?;
    let _ = std::fs::remove_file(LAUNCH_FILE);
    parse(&text)
}

fn parse(text: &str) -> Option<Launch> {
    let mut lines = text.lines().map(|line| line.trim_end_matches('\r'));
    let (kind, value) = lines.next()?.trim().split_once(':')?;
    match kind {
        "title" | "game" => Some(Launch::Title),
        "world" if !value.is_empty() => Some(Launch::World(value.to_owned())),
        "server" if !value.is_empty() => Some(Launch::Server(value.to_owned())),
        "new" => {
            let name = value.trim();
            let mut seed = None;
            let mut creative = false;
            for line in lines {
                if let Some(value) = line.strip_prefix("seed:") {
                    seed = parse_seed(value);
                } else if let Some(value) = line.strip_prefix("creative:") {
                    creative = value.trim() == "1";
                }
            }
            Some(Launch::New {
                name: if name.is_empty() {
                    "Новый мир".to_owned()
                } else {
                    name.to_owned()
                },
                seed,
                creative,
            })
        }
        _ => None,
    }
}

/// Queue an opening exactly like `--world` does: a `Title` for the loading
/// screens and a `pending_entry` that `resume_world_entry` consumes once the
/// world resources exist.
pub(super) fn apply(game: &mut Game<'_>, launch: Launch) -> Result<()> {
    // The launcher may have been used since the game started (its Account or
    // Settings tab): pick up the name and presets it wrote before joining.
    apply_launcher_settings(&mut game.settings);
    game.options.player_name = player_name().or_else(account_name);
    // Play without a world shows the game's own title and world list.
    game.title = Some(game.new_title()?);
    if matches!(launch, Launch::Title) {
        game.pending_entry = None;
        return Ok(());
    }
    game.pending_entry = Some(match launch {
        Launch::Title => unreachable!(),
        Launch::World(folder) => PendingWorldEntry::Local {
            folder,
            name: None,
            seed: None,
            creative: false,
            create: None,
        },
        Launch::New {
            name,
            seed,
            creative,
        } => PendingWorldEntry::Local {
            folder: new_folder(&name)?,
            name: Some(name),
            seed,
            creative,
            create: Some(Box::new(horizon_client::title::WorldOptions::default())),
        },
        Launch::Server(address) => PendingWorldEntry::Server {
            address,
            name: game.options.player_name(),
            cookies: None,
        },
    });
    Ok(())
}

/// The nickname from `horizon-player.txt` (`name:<n>`), as the launcher writes
/// it for the account it signed in. `None` when the file is missing or empty:
/// the game then generates its own offline name.
fn player_name() -> Option<String> {
    let text = std::fs::read_to_string(horizon_client::offline_name::FILE).ok()?;
    text.lines()
        .find_map(|line| line.trim_end_matches('\r').strip_prefix("name:"))
        .map(str::trim)
        .filter(|name| !name.is_empty())
        .map(str::to_owned)
}

/// The account's nickname from `horizon-account.txt`, for a player file that
/// is missing (the launcher always writes both).
fn account_name() -> Option<String> {
    let text = std::fs::read_to_string("horizon-account.txt").ok()?;
    text.lines()
        .find_map(|line| line.trim_end_matches('\r').strip_prefix("name:"))
        .map(str::trim)
        .filter(|name| !name.is_empty())
        .map(str::to_owned)
}

/// The launcher's nickname, applied before the game (and its worlds) are
/// built: the first Play starts the engine with the launch file, but a
/// nickname changed later in the launcher must not wait for the next world.
pub(super) fn apply_identity(options: &mut Options) {
    if let Some(name) = player_name().or_else(account_name) {
        options.player_name = Some(name);
    }
}

/// The folder a new world gets, as `Title::target_folder` (FileUtil.findAvailableName).
fn new_folder(name: &str) -> Result<String> {
    let base: String = name
        .chars()
        .map(|c| {
            if c.is_alphanumeric() || c == ' ' || c == '-' || c == '_' {
                c
            } else {
                '_'
            }
        })
        .collect();
    let base = if base.trim().is_empty() {
        "World".to_owned()
    } else {
        base.trim().to_owned()
    };
    let saves = std::env::current_dir()?.join("saves");
    let mut folder = base.clone();
    let mut n = 1;
    while saves.join(&folder).exists() {
        folder = format!("{base} ({n})");
        n += 1;
    }
    Ok(folder)
}

/// Fold the launcher's accent and memory presets into the settings before the
/// loader and `Game` are built.
pub(super) fn apply_launcher_settings(settings: &mut Settings) {
    let Ok(text) = std::fs::read_to_string(SETTINGS_FILE) else {
        return;
    };
    let mut changed = false;
    for line in text.lines() {
        let Some((key, value)) = line.split_once(':') else {
            continue;
        };
        match key.trim() {
            "accent" => {
                if let Ok(index) = value.trim().parse::<u8>() {
                    settings.extras.accent = index.min(ACCENTS.len() as u8 - 1);
                    changed = true;
                }
            }
            "memory" => {
                if let Some(preset) = value
                    .trim()
                    .parse::<usize>()
                    .ok()
                    .and_then(|i| MEMORY.get(i))
                {
                    settings.render_distance = preset.render_distance;
                    settings.simulation_distance = preset.simulation_distance;
                    settings.max_fps = preset.max_fps;
                    settings.entity_distance = preset.entity_distance;
                    settings.particles = preset.particles;
                    changed = true;
                }
            }
            // The launcher's own controls, over the memory preset: the player
            // picked them explicitly, so they win over the preset's numbers.
            "distance" => {
                if let Ok(distance) = value.trim().parse::<i32>() {
                    settings.render_distance = distance.clamp(2, 32);
                    settings.simulation_distance =
                        settings.simulation_distance.min(settings.render_distance);
                    changed = true;
                }
            }
            "fov" => {
                if let Ok(fov) = value.trim().parse::<f32>() {
                    settings.fov = fov.clamp(30.0, 110.0);
                    changed = true;
                }
            }
            "sensitivity" => {
                if let Ok(percent) = value.trim().parse::<f32>() {
                    settings.sensitivity = (percent / 100.0).clamp(0.1, 1.0);
                    changed = true;
                }
            }
            "volume" => {
                if let Ok(percent) = value.trim().parse::<f32>() {
                    settings.master_volume = (percent / 100.0).clamp(0.0, 1.0);
                    settings.volumes[0] = settings.master_volume;
                    changed = true;
                }
            }
            "gui" => {
                if let Ok(scale) = value.trim().parse::<u32>() {
                    settings.gui_scale = scale.min(4);
                    changed = true;
                }
            }
            "invert_y" => {
                settings.invert_y = value.trim() == "1";
                changed = true;
            }
            "bobbing" => {
                settings.view_bobbing = value.trim() == "1";
                changed = true;
            }
            _ => {}
        }
    }
    // Keep the game's own files in step (`accentColor` is in horizon-extras.txt).
    if changed && let Ok(dir) = std::env::current_dir() {
        settings.save(&dir.join("options.txt"));
    }
}
